import { expect, test } from "@playwright/test";
import { agent, item, newRoom } from "./support";

// A thread at a place of a block is marked where that place is on each
// page (the block's `locate`), whatever the order the page draws it in;
// its mark opens it in the panel.
test("a thread's mark is at its place, on each page, and opens it", async ({ page, browser, request }) => {
  const room = newRoom();
  await page.goto(`/one?room=${room}&as=Ada&comments=1`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  const other = await (await browser.newContext()).newPage();
  await other.goto(`/one?room=${room}&as=Grace&comments=1&order=desc`);
  await expect(other.locator("[data-phx-main].phx-connected")).toBeVisible();

  await agent(request, "comment", { room: `page:${room}`, body: "This one first?", document: `page:${room}/list`, at: { path: ["item", "6"] } });

  for (const one of [page, other]) {
    const mark = one.locator(".issho-comment-mark");
    await expect(mark).toHaveText("1");
    await expect(mark).toHaveAttribute("aria-label", "1 comment, Agent: This one first?");
    const target = await item(one, 6);
    await expect.poll(async () => {
      const box = await mark.boundingBox();
      return box ? Math.abs(box.x + box.width / 2 - (target.x + target.width)) < 4 && Math.abs(box.y + box.height / 2 - target.y) < 4 : false;
    }).toBe(true);
  }

  await page.locator(".issho-comment-mark").click();
  await expect(page.locator(".issho-thread[data-focused]")).toContainText("This one first?");
  await expect(page.locator(".issho-comment-mark")).toHaveAttribute("data-focused", "");
  await other.context().close();
});

// A reply in the panel goes to everyone's panel, and resolving the thread
// takes its mark away.
test("a reply, and resolving a thread", async ({ page, browser, request }) => {
  const room = newRoom();
  await page.goto(`/one?room=${room}&as=Ada&comments=1`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
  const other = await (await browser.newContext()).newPage();
  await other.goto(`/one?room=${room}&as=Grace&comments=1`);
  await expect(other.locator("[data-phx-main].phx-connected")).toBeVisible();

  await agent(request, "comment", { room: `page:${room}`, body: "Look here", document: `page:${room}/list`, at: { path: ["item", "2"] } });
  await other.locator(".issho-thread-place").click();
  await other.getByLabel("Reply", { exact: true }).fill("Looking");
  await other.getByRole("button", { name: "Send reply" }).click();

  await page.locator(".issho-thread-place").click();
  await expect(page.locator(".issho-thread")).toContainText("Looking");
  await expect(page.locator(".issho-comment-mark")).toHaveText("2");

  await page.getByRole("button", { name: "Resolve thread" }).click();
  await expect(other.locator(".issho-comment-mark")).toHaveCount(0);
  await expect(other.locator(".issho-comments-empty-title")).toHaveText("No open comments.");
  await other.context().close();
});

// The @ of a comment: a list of the room's people, filtered as one types,
// picked from the keyboard; the comment mentions whom one picked.
test("an @ offers the room's people, and a pick mentions them", async ({ page, browser }) => {
  const room = newRoom();
  const other = await (await browser.newContext()).newPage();
  await other.goto(`/one?room=${room}&as=Grace&comments=1`);
  await expect(other.locator("[data-phx-main].phx-connected")).toBeVisible();
  await page.goto(`/one?room=${room}&as=Ada&comments=1`);
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();

  const box = page.getByLabel("New comment");
  await box.click();
  await box.pressSequentially("Look, @gr");
  const list = page.getByRole("listbox", { name: "People to mention" });
  await expect(list).toBeVisible();
  await expect(list.getByRole("option")).toHaveCount(1);
  await expect(list.getByRole("option")).toHaveAccessibleName("Grace");
  await expect(box).toHaveAttribute("aria-expanded", "true");

  await box.press("Enter");
  await expect(list).toBeHidden();
  await expect(box).toHaveValue("Look, @Grace ");
  await page.keyboard.type("what do you think?");
  await page.getByRole("button", { name: "Comment", exact: true }).click();

  await expect(other.locator(".issho-thread .issho-mention")).toHaveText("@Grace");
  await other.context().close();
});
