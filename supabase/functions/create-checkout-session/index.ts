import { createClient } from "npm:@supabase/supabase-js@2";
import {
  corsHeaders,
  jsonResponse,
  requestOriginAllowed,
  siteUrl
} from "../_shared/http.ts";

type CartItem = {
  product_id: string;
  quantity: number;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY") || "";

function normalizedItems(value: unknown): CartItem[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > 50) return [];
  const items = value.map((item) => {
    const record = item && typeof item === "object" ? item as Record<string, unknown> : {};
    return {
      product_id: String(record.product_id || "").trim(),
      quantity: Math.min(99, Math.max(1, Math.floor(Number(record.quantity) || 1)))
    };
  });
  return items.every((item) => item.product_id) ? items : [];
}

function checkoutReturnUrl(status: "success" | "cancelled", orderId = ""): string {
  const url = new URL(siteUrl());
  url.searchParams.set("payment", status);
  if (status === "success") {
    url.searchParams.set("session_id", "{CHECKOUT_SESSION_ID}");
  } else if (orderId) {
    url.searchParams.set("order_id", orderId);
  }
  return url.toString();
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(request) });
  }
  if (request.method !== "POST") return jsonResponse(request, { error: "Method not allowed" }, 405);
  if (!requestOriginAllowed(request)) return jsonResponse(request, { error: "Origin not allowed" }, 403);
  if (!stripeSecretKey) return jsonResponse(request, { error: "Online payments are not configured" }, 503);

  const authorization = request.headers.get("authorization");
  if (!authorization) return jsonResponse(request, { error: "Sign in before checkout" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return jsonResponse(request, { error: "Invalid request" }, 400);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false }
  });
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false }
  });

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return jsonResponse(request, { error: "Authentication required" }, 401);

  if (body.action === "cancel") {
    const orderId = String(body.order_id || "").trim();
    if (!orderId) return jsonResponse(request, { error: "Order is required" }, 400);
    const { data: order, error: orderError } = await userClient
      .from("orders")
      .select("id,payment_status,stripe_checkout_session_id")
      .eq("id", orderId)
      .eq("user_id", userData.user.id)
      .single();
    if (orderError || !order) return jsonResponse(request, { error: "Order not found" }, 404);
    if (order.payment_status === "paid") return jsonResponse(request, { error: "Paid orders cannot be cancelled" }, 409);

    if (order.stripe_checkout_session_id) {
      const expireResponse = await fetch(
        "https://api.stripe.com/v1/checkout/sessions/" + encodeURIComponent(order.stripe_checkout_session_id) + "/expire",
        {
          method: "POST",
          headers: {
            "Authorization": "Bearer " + stripeSecretKey,
            "Content-Type": "application/x-www-form-urlencoded"
          }
        }
      );
      if (!expireResponse.ok) {
        const expireResult = await expireResponse.json().catch(() => ({}));
        return jsonResponse(request, { error: expireResult?.error?.message || "Unable to cancel payment" }, 409);
      }
    }

    const { error: cancelError } = await userClient.rpc("cancel_payment_order", { p_order_id: orderId });
    if (cancelError) return jsonResponse(request, { error: cancelError.message }, 400);
    return jsonResponse(request, { cancelled: true });
  }

  const items = normalizedItems(body.items);
  if (!items.length) return jsonResponse(request, { error: "Cart is empty or invalid" }, 400);

  const { data: orderId, error: orderError } = await userClient.rpc("create_payment_order", {
    p_items: items,
    p_customer_voucher_id: body.customer_voucher_id || null
  });
  if (orderError || !orderId) {
    return jsonResponse(request, { error: orderError?.message || "Unable to create order" }, 400);
  }

  const { data: order, error: orderLoadError } = await adminClient
    .from("orders")
    .select("id,order_number,subtotal,discount_amount,total,voucher_code,order_items(product_title,unit_price,quantity)")
    .eq("id", orderId)
    .single();

  if (orderLoadError || !order) {
    await adminClient.from("orders").delete().eq("id", orderId);
    return jsonResponse(request, { error: "Unable to prepare payment" }, 500);
  }

  const form = new URLSearchParams();
  form.set("mode", "payment");
  form.set("automatic_payment_methods[enabled]", "true");
  form.set("submit_type", "pay");
  form.set("success_url", checkoutReturnUrl("success"));
  form.set("cancel_url", checkoutReturnUrl("cancelled", order.id));
  form.set("client_reference_id", order.id);
  form.set("metadata[order_id]", order.id);
  form.set("metadata[order_number]", order.order_number);
  form.set("payment_intent_data[metadata][order_id]", order.id);
  form.set("payment_intent_data[metadata][order_number]", order.order_number);
  if (userData.user.email) form.set("customer_email", userData.user.email);
  form.set("locale", body.locale === "zh" ? "zh" : "en");

  if (Number(order.discount_amount) > 0) {
    const coupon = new URLSearchParams();
    coupon.set("amount_off", String(Math.round(Number(order.discount_amount) * 100)));
    coupon.set("currency", "nzd");
    coupon.set("duration", "once");
    coupon.set("name", order.voucher_code ? "GO GO SHOP " + order.voucher_code : "GO GO SHOP voucher");
    coupon.set("metadata[order_id]", order.id);

    const couponResponse = await fetch("https://api.stripe.com/v1/coupons", {
      method: "POST",
      headers: {
        "Authorization": "Bearer " + stripeSecretKey,
        "Content-Type": "application/x-www-form-urlencoded",
        "Idempotency-Key": "gogoshop-voucher-" + order.id
      },
      body: coupon
    });
    const couponResult = await couponResponse.json().catch(() => ({}));
    if (!couponResponse.ok || !couponResult.id) {
      await adminClient.from("orders").delete().eq("id", order.id);
      return jsonResponse(request, {
        error: couponResult?.error?.message || "Unable to apply voucher"
      }, 502);
    }
    form.set("discounts[0][coupon]", couponResult.id);
  }

  (order.order_items || []).forEach((item: {
    product_title: string;
    unit_price: number;
    quantity: number;
  }, index: number) => {
    const prefix = "line_items[" + index + "]";
    form.set(prefix + "[price_data][currency]", "nzd");
    form.set(prefix + "[price_data][unit_amount]", String(Math.round(Number(item.unit_price) * 100)));
    form.set(prefix + "[price_data][product_data][name]", item.product_title);
    form.set(prefix + "[quantity]", String(item.quantity));
  });

  const stripeResponse = await fetch("https://api.stripe.com/v1/checkout/sessions", {
    method: "POST",
    headers: {
      "Authorization": "Bearer " + stripeSecretKey,
      "Content-Type": "application/x-www-form-urlencoded",
      "Idempotency-Key": "gogoshop-order-" + order.id
    },
    body: form
  });
  const stripeSession = await stripeResponse.json();

  if (!stripeResponse.ok || !stripeSession.id || !stripeSession.url) {
    await adminClient.from("orders").delete().eq("id", order.id);
    return jsonResponse(request, {
      error: stripeSession?.error?.message || "Unable to start secure payment"
    }, 502);
  }

  const { error: updateError } = await adminClient
    .from("orders")
    .update({
      payment_status: "pending",
      stripe_checkout_session_id: stripeSession.id
    })
    .eq("id", order.id);

  if (updateError) {
    await adminClient.from("orders").delete().eq("id", order.id);
    return jsonResponse(request, { error: "Unable to link payment to order" }, 500);
  }

  return jsonResponse(request, {
    checkout_url: stripeSession.url,
    order_id: order.id,
    order_number: order.order_number
  });
});
