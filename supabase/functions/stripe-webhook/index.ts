import { createClient } from "npm:@supabase/supabase-js@2";

const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET") || "";

function secureEqual(left: string, right: string): boolean {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

async function hmacHex(value: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(value));
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function verifyStripeSignature(payload: string, header: string): Promise<boolean> {
  const values = header.split(",").map((part) => part.trim().split("="));
  const timestamp = values.find(([key]) => key === "t")?.[1] || "";
  const signatures = values.filter(([key]) => key === "v1").map(([, value]) => value);
  if (!timestamp || !signatures.length) return false;
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;
  const expected = await hmacHex(timestamp + "." + payload, webhookSecret);
  return signatures.some((signature) => secureEqual(signature, expected));
}

Deno.serve(async (request: Request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (!webhookSecret) return new Response("Webhook secret is missing", { status: 503 });

  const payload = await request.text();
  const signature = request.headers.get("stripe-signature") || "";
  if (!await verifyStripeSignature(payload, signature)) {
    return new Response("Invalid signature", { status: 400 });
  }

  let event;
  try {
    event = JSON.parse(payload);
  } catch {
    return new Response("Invalid payload", { status: 400 });
  }

  const object = event?.data?.object || {};
  const orderId = object?.metadata?.order_id || object?.client_reference_id;
  const paymentIntentId = typeof object?.payment_intent === "string"
    ? object.payment_intent
    : object?.payment_intent?.id || (object?.object === "payment_intent" ? object.id : null);

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false }
  });

  if ([
    "checkout.session.completed",
    "checkout.session.async_payment_succeeded"
  ].includes(event.type) && orderId && ["paid", "no_payment_required"].includes(object.payment_status)) {
    const { error } = await adminClient
      .from("orders")
      .update({
        payment_status: "paid",
        stripe_payment_intent_id: paymentIntentId,
        paid_at: new Date().toISOString()
      })
      .eq("id", orderId)
      .neq("payment_status", "refunded");
    if (error) return new Response("Database update failed", { status: 500 });
    const { error: voucherError } = await adminClient
      .from("customer_vouchers")
      .update({ used_at: new Date().toISOString() })
      .eq("order_id", orderId);
    if (voucherError) return new Response("Voucher update failed", { status: 500 });
  }

  if ([
    "checkout.session.expired",
    "checkout.session.async_payment_failed",
    "payment_intent.payment_failed"
  ].includes(event.type) && orderId) {
    const { error } = await adminClient
      .from("orders")
      .update({ payment_status: "failed" })
      .eq("id", orderId)
      .neq("payment_status", "paid")
      .neq("payment_status", "refunded");
    if (error) return new Response("Database update failed", { status: 500 });
    const { error: voucherError } = await adminClient
      .from("customer_vouchers")
      .update({ order_id: null, reserved_at: null })
      .eq("order_id", orderId)
      .is("used_at", null);
    if (voucherError) return new Response("Voucher update failed", { status: 500 });
  }

  const fullyRefunded = object?.refunded === true
    || (Number(object?.amount) > 0 && Number(object?.amount_refunded) >= Number(object?.amount));
  if (event.type === "charge.refunded" && fullyRefunded && (orderId || paymentIntentId)) {
    let refundedOrderId = orderId;
    if (!refundedOrderId && paymentIntentId) {
      const { data: refundedOrder, error: lookupError } = await adminClient
        .from("orders")
        .select("id")
        .eq("stripe_payment_intent_id", paymentIntentId)
        .maybeSingle();
      if (lookupError) return new Response("Order lookup failed", { status: 500 });
      refundedOrderId = refundedOrder?.id;
    }

    let query = adminClient
      .from("orders")
      .update({ payment_status: "refunded" });
    query = refundedOrderId
      ? query.eq("id", refundedOrderId)
      : query.eq("stripe_payment_intent_id", paymentIntentId);
    const { error } = await query;
    if (error) return new Response("Database update failed", { status: 500 });
    if (refundedOrderId) {
      const { error: voucherError } = await adminClient
        .from("customer_vouchers")
        .update({ order_id: null, reserved_at: null, used_at: null })
        .eq("order_id", refundedOrderId);
      if (voucherError) return new Response("Voucher update failed", { status: 500 });
    }
  }

  return new Response("ok", { status: 200 });
});
