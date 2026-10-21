// Helpers for the browser tests of the page layer.

import { expect, type APIRequestContext, type Page } from "@playwright/test";

let rooms = 0;

/** A room of its own for a test, so that tests that run at once do not meet. */
export const newRoom = (): string => `t${process.pid}-${Date.now()}-${rooms++}`;

/** Opens a page of the room as a person, and waits for its pointers and people. */
export async function open(page: Page, path: string, room: string, as: string, extra = ""): Promise<void> {
  await page.goto(`${path}?room=${room}&as=${as}${extra}`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  await expect(page.locator(".issho-pointers")).toBeAttached();
}

/** The pointer of someone on a page. */
export const pointer = (page: Page, key: string) => page.locator(`.issho-pointer[data-key="${key}"]`);

/**
 * The agent of the test server calls a room tool, in one of its sessions
 * ("a" unless given), the first call of a session saying for whom it works.
 */
export async function agent(request: APIRequestContext, tool: string, args: Record<string, unknown>, session = "a", onBehalfOf?: string): Promise<unknown> {
  const response = await request.post("/agent", { data: { tool, arguments: args, session, on_behalf_of: onBehalfOf } });
  const reply = (await response.json()) as { result?: unknown; error?: string };
  if (reply.error) throw new Error(`${tool}: ${reply.error}`);
  return reply.result;
}

/** Where an item of the block is on a page. */
export async function item(page: Page, n: number): Promise<{ x: number; y: number; width: number; height: number }> {
  const box = await page.locator(`#list li[data-item="${n}"]`).boundingBox();
  if (!box) throw new Error(`no item ${n}`);
  return box;
}
