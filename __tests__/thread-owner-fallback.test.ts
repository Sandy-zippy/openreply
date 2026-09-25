import { afterEach, describe, expect, it, vi } from "vitest";
import { sendDirectMessage, setThreadOwnerFallback } from "@/lib/meta/client";

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status });
const notOwner = () =>
  json(400, { error: { message: "not the thread owner", code: 100, error_subcode: 2534037 } });

afterEach(() => vi.unstubAllGlobals());

describe("DM thread-owner fallback", () => {
  it("re-sends a refused DM as a private reply to the user's comment", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(notOwner())
      .mockResolvedValueOnce(json(200, { recipient_id: "u1", message_id: "m1" }));
    vi.stubGlobal("fetch", fetchMock);
    setThreadOwnerFallback(async () => "555");

    await expect(sendDirectMessage("t", "ig", "u1", "hi")).resolves.toMatchObject({ message_id: "m1" });
    expect(JSON.parse(fetchMock.mock.calls[1][1].body).recipient).toEqual({ comment_id: "555" });
  });

  it("treats Meta's generic code 1 on the fallback as delivered", async () => {
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce(notOwner())
      .mockResolvedValueOnce(json(500, { error: { message: "unknown", code: 1 } })));
    setThreadOwnerFallback(async () => "555");
    await expect(sendDirectMessage("t", "ig", "u1", "hi")).resolves.toMatchObject({ recipient_id: "u1" });
  });

  it("still throws when there is no comment to fall back to", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(notOwner()));
    setThreadOwnerFallback(async () => null);
    await expect(sendDirectMessage("t", "ig", "u1", "hi")).rejects.toThrow(/thread owner/);
  });
});
