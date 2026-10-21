import { expect, test } from "@playwright/test";
import { agent, item, newRoom, open, pointer } from "./support";

// A person's pointer over a block is a place of its document (the block's
// `point`), which each page draws where that place is there (its `locate`):
// the same item, at the same spot of it, though the other page draws the
// items in the other order.
test("a pointer over a block is on the same place of the other's page, in another order", async ({ page, browser }) => {
  const room = newRoom();
  await open(page, "/one", room, "Ada");
  const other = await (await browser.newContext()).newPage();
  await open(other, "/one", room, "Grace", "&order=desc");

  const mine = await item(page, 3);
  await page.mouse.move(mine.x + mine.width / 4, mine.y + mine.height / 2);

  const theirs = await item(other, 3);
  expect(Math.abs(theirs.y - mine.y)).toBeGreaterThan(40);
  await expect(pointer(other, "Ada")).toBeVisible();
  await expect.poll(async () => {
    const box = await pointer(other, "Ada").boundingBox();
    return box ? Math.abs(box.x - (theirs.x + theirs.width / 4)) < 3 && Math.abs(box.y - (theirs.y + theirs.height / 2)) < 3 : false;
  }).toBe(true);
  await other.context().close();
});

// Following, from the people list: a pill in their colour with Stop, and a
// frame of it around the page; Stop ends it.
test("following someone: the pill, the frame, and Stop", async ({ page, browser }) => {
  const room = newRoom();
  await open(page, "/one", room, "Ada");
  const other = await (await browser.newContext()).newPage();
  await open(other, "/one", room, "Grace");
  // Grace's pointer is nowhere on the page: the frame does not wait for it.
  const avatar = page.locator("#people .issho-person-follow");
  await expect(avatar).toHaveCount(1);
  await avatar.click();
  const pill = page.locator("#people .issho-following");
  await expect(pill).toContainText("Following Grace");
  await expect(page.locator(".issho-pointers")).toHaveAttribute("data-following", "");
  await expect(avatar).toHaveAttribute("aria-pressed", "true");

  await pill.getByRole("button", { name: "Stop" }).click();
  await expect(pill).toHaveCount(0);
  await expect(page.locator(".issho-pointers")).not.toHaveAttribute("data-following", "");
  await other.context().close();
});

// An agent goes to a place of the block: its pointer goes there, on the
// way (it glides), and is drawn at that place.
test("an agent's pointer goes to its place in a block", async ({ page, request }) => {
  const room = newRoom();
  await open(page, "/one", room, "Ada");
  await agent(request, "join_room", { room: `page:${room}` });
  await expect(pointer(page, "agent:e2e")).toHaveCount(0);

  await agent(request, "point", { room: `page:${room}`, document: `page:${room}/list`, at: { path: ["item", "6"] } });
  const target = await item(page, 6);
  await expect.poll(async () => {
    const box = await pointer(page, "agent:e2e").boundingBox();
    return box ? Math.abs(box.x - (target.x + target.width)) < 3 && Math.abs(box.y - (target.y + target.height)) < 3 : false;
  }).toBe(true);
  await expect(pointer(page, "agent:e2e")).toContainText("Agent");
});

// An agent clicks a link that takes followers along (data-issho-follow):
// the page of whom follows it goes there too; the others stay.
test("an agent's click on a link takes its followers along, and no one else", async ({ page, browser, request }) => {
  const room = newRoom();
  await open(page, "/one", room, "Ada");
  const other = await (await browser.newContext()).newPage();
  await open(other, "/one", room, "Grace");
  await agent(request, "join_room", { room: `page:${room}` });
  await agent(request, "point", { room: `page:${room}`, anchor: "next" });

  // Ada follows the agent.
  const avatar = page.locator('#people li[data-key="agent:e2e"] .issho-person-follow');
  await avatar.click();
  await expect(page.locator("#people .issho-following")).toContainText("Following Agent");

  // It looks around (it sees the link), and clicks it.
  const around = (await agent(request, "look_around", { room: `page:${room}` })) as { anchors: { name: string; follow: boolean }[] };
  expect(around.anchors).toContainEqual(expect.objectContaining({ name: "next", follow: true }));
  await agent(request, "click", { room: `page:${room}`, anchor: "next" });

  await expect(page.locator("#title")).toHaveText("Page two");
  await expect(page).toHaveURL(/\/two\?/);
  await expect(other.locator("#title")).toHaveText("Page one");
  await other.context().close();
});

// An agent goes to another page of the app (navigate): it sees where the
// links go and where each person is (look_around), and the page of whom
// follows it goes there too; the others stay. Only a path of the app goes.
test("an agent navigates to another page, and takes its followers along", async ({ page, browser, request }) => {
  const room = newRoom();
  await open(page, "/one", room, "Ada");
  const other = await (await browser.newContext()).newPage();
  await open(other, "/one", room, "Grace");
  await agent(request, "join_room", { room: `page:${room}` });
  await agent(request, "point", { room: `page:${room}`, anchor: "next" });
  await page.locator('#people li[data-key="agent:e2e"] .issho-person-follow').click();
  await expect(page.locator("#people .issho-following")).toContainText("Following Agent");

  type Around = { anchors: { name: string; href?: string }[]; people: { key: string; pages: string[] }[] };
  await expect.poll(async () => {
    const around = (await agent(request, "look_around", { room: `page:${room}` })) as Around;
    const next = around.anchors.find((anchor) => anchor.name === "next");
    const ada = around.people.find((person) => person.key === "Ada");
    return Boolean(next?.href?.startsWith("/two?") && ada?.pages.some((path) => path.startsWith("/one?")));
  }).toBe(true);

  await agent(request, "navigate", { room: `page:${room}`, path: `/two?room=${room}&as=Ada` });
  await expect(page.locator("#title")).toHaveText("Page two");
  await expect(page).toHaveURL(/\/two\?/);
  await expect(other.locator("#title")).toHaveText("Page one");

  // Another site is no page of the app.
  await expect(agent(request, "navigate", { room: `page:${room}`, path: "//example.com/" })).rejects.toThrow(/navigate/);
  await other.context().close();
});
