import { expect, test } from "@playwright/test";
import { agent, newRoom, open } from "./support";

// An agent at work for Ada: its task and steps in the bar as it goes, and
// Ada's Pause, which its next change hears; Resume, and it goes on.
test("an agent's task, as it goes, and its person pausing it", async ({ page, request }) => {
  const room = newRoom();
  await open(page, "/one", room, "Ada");
  const bar = page.locator("#agents");
  await expect(bar).toBeHidden();

  const session = `work-${room}`;
  await agent(request, "start_task", { room: `page:${room}`, title: "Tidy the list", steps: ["Read", "Sort"] }, session, "Ada");
  await expect(bar).toBeVisible();
  await expect(bar.locator(".issho-agent")).toContainText("Tidy the list");
  await expect(bar.locator(".issho-agent")).toContainText("for Ada");
  await expect(bar.locator(".issho-agent-steps li[aria-current='step']")).toHaveText("Read");

  // Ada's focus on Pause stays there as the agent goes on.
  await bar.getByRole("button", { name: "Pause Agent" }).focus();
  await agent(request, "progress", { room: `page:${room}`, step: "Read" }, session);
  await expect(bar.locator(".issho-agent-progress")).toHaveText("Step 2 of 2 · Sort");
  await expect(bar.locator(".issho-agent-steps li[aria-current='step']")).toHaveText("Sort");
  await expect(bar.getByRole("button", { name: "Pause Agent" })).toBeFocused();
  await expect(bar.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "1");

  await bar.getByRole("button", { name: "Pause Agent" }).click();
  await expect(bar.locator(".issho-agent-state")).toHaveText("Paused by Ada");
  const ops = [{ op: "set", path: ["title"], value: "Sorted" }];
  await expect(agent(request, "change_document", { room: `page:${room}`, ops }, session)).rejects.toThrow(/Ada paused you/);

  await bar.getByRole("button", { name: "Resume Agent" }).click();
  await expect(bar.locator(".issho-agent-state")).toHaveText("Working");
  await expect.poll(async () => agent(request, "change_document", { room: `page:${room}`, ops }, session).then(() => "ok", (error: Error) => error.message)).toBe("ok");

  await agent(request, "finish_task", { room: `page:${room}`, summary: "Sorted." }, session);
  await expect(bar).toBeHidden();
});
