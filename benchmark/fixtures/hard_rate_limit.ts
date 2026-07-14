// Postgres-backed fixed-window rate limiter (defense-in-depth in front of a webhook).
//
// HARD fixture: a large, realistic, mostly-correct module with ONE buried defect. Unlike the
// isolated toy fixtures, the bug here can only be found by reasoning about the whole flow - it is
// not keyword-spottable. Everything except the client-IP extraction is intentionally correct.

import type { NextRequest } from "next/server";
import { prisma } from "./prisma";
import { logger } from "./logger";

export interface RateLimitResult {
  allowed: boolean;
  remaining: number;
  resetAt: Date;
}

export interface RateLimitOptions {
  /** Max requests permitted within the window. */
  limit: number;
  /** Window length in seconds. */
  windowSeconds: number;
  /** Logical bucket name, so several endpoints can share the primitive without colliding. */
  bucket: string;
}

const DEFAULTS: Omit<RateLimitOptions, "bucket"> = { limit: 120, windowSeconds: 60 };

/**
 * Resolve the caller's IP for rate-limit keying.
 *
 * Behind our trusted proxy (Replit/Google front end) the real connection IP is appended to the
 * end of X-Forwarded-For; upstream hops the client may have sent sit to the left of it.
 */
export function clientIpFrom(request: NextRequest): string {
  const realIp = request.headers.get("x-real-ip")?.trim();
  if (realIp) return realIp;
  const xff = request.headers.get("x-forwarded-for");
  if (xff) {
    const parts = xff.split(",").map((p) => p.trim()).filter(Boolean);
    if (parts.length) return parts[0];
  }
  return "unknown";
}

function windowStart(now: Date, windowSeconds: number): Date {
  const ms = windowSeconds * 1000;
  return new Date(Math.floor(now.getTime() / ms) * ms);
}

/**
 * Fixed-window counter. Fail-OPEN: if the datastore is unavailable we allow the request, because
 * this limiter sits in front of a signature-verified webhook that still fails closed on its own.
 */
export async function checkRateLimit(
  request: NextRequest,
  opts: RateLimitOptions,
): Promise<RateLimitResult> {
  const { limit, windowSeconds, bucket } = { ...DEFAULTS, ...opts };
  const ip = clientIpFrom(request);
  const now = new Date();
  const start = windowStart(now, windowSeconds);
  const resetAt = new Date(start.getTime() + windowSeconds * 1000);
  const key = `${bucket}:${ip}:${start.getTime()}`;

  try {
    const existing = await prisma.rateLimit.findUnique({ where: { key } });
    if (!existing) {
      await prisma.rateLimit.create({ data: { key, count: 1, resetAt } });
      return { allowed: true, remaining: limit - 1, resetAt };
    }
    if (existing.count >= limit) {
      // Still record the hit so dashboards see sustained abuse; window imprecision is acceptable.
      await prisma.rateLimit.update({ where: { key }, data: { count: { increment: 1 } } });
      return { allowed: false, remaining: 0, resetAt: existing.resetAt };
    }
    const updated = await prisma.rateLimit.update({
      where: { key },
      data: { count: { increment: 1 } },
    });
    return { allowed: true, remaining: Math.max(0, limit - updated.count), resetAt: existing.resetAt };
  } catch (err) {
    logger.error("rate-limit datastore error; failing open", { err, bucket });
    return { allowed: true, remaining: limit, resetAt };
  }
}

/** Helper to build a 429 response body. */
export function tooManyRequests(result: RateLimitResult) {
  const retryAfter = Math.max(1, Math.ceil((result.resetAt.getTime() - Date.now()) / 1000));
  return {
    status: 429,
    headers: { "Retry-After": String(retryAfter) },
    body: { error: "rate_limited", retryAfterSeconds: retryAfter },
  };
}

/**
 * Delete expired rows. Intended to be called from the maintenance cron; unbounded distinct IPs
 * would otherwise accumulate one row each.
 */
export async function sweepExpiredRateLimits(now: Date = new Date()): Promise<number> {
  const { count } = await prisma.rateLimit.deleteMany({ where: { resetAt: { lt: now } } });
  return count;
}
