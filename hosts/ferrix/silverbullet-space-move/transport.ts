import type {
  FileMeta,
  FileSnapshot,
  SpaceConfig,
  SpaceId,
  WritePolicy,
} from "./types.ts";

export interface HttpTransportOptions {
  origin: string;
  spaces: SpaceConfig[];
  maxBytes?: number;
  fetcher?: typeof fetch;
}

export class HttpTransport {
  private origin: string;
  private spaces: Map<SpaceId, SpaceConfig>;
  private maxBytes: number;
  private fetcher: typeof fetch;

  constructor(options: HttpTransportOptions) {
    const origin = new URL(options.origin);
    if (
      origin.origin !== options.origin ||
      origin.username ||
      origin.password ||
      (origin.protocol !== "https:" &&
        !(
          origin.protocol === "http:" &&
          ["127.0.0.1", "localhost", "[::1]"].includes(origin.hostname)
        ))
    ) {
      throw new Error("A trusted HTTPS or loopback origin is required.");
    }
    this.origin = origin.origin;
    this.spaces = new Map(
      options.spaces.map((space) => {
        if (
          !(["personal", "ksp"] as string[]).includes(space.id) ||
          (space.prefix !== "" && !/^\/[A-Za-z0-9_-]+$/.test(space.prefix))
        ) {
          throw new Error("Invalid configured space.");
        }
        return [space.id, { ...space }];
      }),
    );
    if (
      this.spaces.size !== 2 ||
      new Set(options.spaces.map((space) => space.prefix)).size !== 2
    ) {
      throw new Error("Two distinct configured spaces are required.");
    }
    this.maxBytes = options.maxBytes ?? 67108864;
    if (
      !Number.isSafeInteger(this.maxBytes) ||
      this.maxBytes < 1 ||
      this.maxBytes > 268435456
    ) {
      throw new Error("Invalid transfer byte limit.");
    }
    this.fetcher = options.fetcher ?? globalThis.fetch.bind(globalThis);
  }

  private url(space: SpaceId, path?: string): string {
    const configured = this.spaces.get(space);
    if (!configured) throw new Error("Unknown space.");
    let result = this.origin + configured.prefix + "/.fs";
    if (path !== undefined) {
      if (
        !path ||
        path.includes("\\") ||
        /[\x00-\x1f\x7f]/.test(path) ||
        path.split("/").some((part) => !part || part === "." || part === "..")
      ) {
        throw new Error("Invalid space-relative path.");
      }
      const segments = path.split("/").map(encodeURIComponent);
      // Match upstream's WebKit header workaround without changing the filename.
      segments[segments.length - 1] = segments.at(-1)!.replace(/\.([^.]*)$/, "%2E$1");
      result += "/" + segments.join("/");
    }
    return result;
  }

  private async request(
    space: SpaceId,
    path: string | undefined,
    options: RequestInit,
  ): Promise<Response> {
    const headers = new Headers(options.headers);
    headers.set("X-Sync-Mode", "true");
    headers.set("X-Source", "space-move");
    const response = await this.fetcher(this.url(space, path), {
      ...options,
      headers,
      credentials: "same-origin",
      redirect: "error",
      cache: "no-store",
      signal: AbortSignal.timeout(60000),
    });
    if (response.status === 401 || response.status === 403) {
      throw new Error("Sign in with write access to both spaces before moving files.");
    }
    if (response.status === 412 || response.status === 409) {
      throw new Error("Revision conflict: refresh and review the operation again.");
    }
    if (
      response.redirected ||
      response.type === "opaqueredirect" ||
      (response.status >= 300 && response.status < 400)
    ) {
      throw new Error("Authentication redirects are not allowed during a move.");
    }
    if (!response.ok && response.status !== 404) {
      throw new Error(`SilverBullet file request failed (${response.status}).`);
    }
    return response;
  }

  private async bytes(response: Response): Promise<Uint8Array> {
    if (Number(response.headers.get("Content-Length")) > this.maxBytes) {
      await response.body?.cancel();
      throw new Error("File exceeds the configured transfer limit.");
    }
    const reader = response.body?.getReader();
    if (!reader) return new Uint8Array();
    const chunks: Uint8Array[] = [];
    let length = 0;
    try {
      while (true) {
        const part = await reader.read();
        if (part.done) break;
        length += part.value.byteLength;
        if (length > this.maxBytes)
          throw new Error("File exceeds the configured transfer limit.");
        chunks.push(part.value);
      }
    } catch (error) {
      await reader.cancel();
      throw error;
    } finally {
      reader.releaseLock();
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  }

  async list(space: SpaceId): Promise<FileMeta[]> {
    const response = await this.request(space, undefined, {
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error("Could not list the selected space.");
    const value: unknown = JSON.parse(
      new TextDecoder().decode(await this.bytes(response)),
    );
    if (!Array.isArray(value))
      throw new Error("Incomplete or malformed file inventory.");
    const seen = new Set<string>();
    return value.map((entry: Record<string, unknown>) => {
      if (
        !entry ||
        typeof entry.name !== "string" ||
        typeof entry.size !== "number" ||
        !Number.isSafeInteger(entry.size) ||
        entry.size < 0 ||
        seen.has(entry.name)
      ) {
        throw new Error("Incomplete or malformed file inventory.");
      }
      this.url(space, entry.name);
      seen.add(entry.name);
      return {
        path: entry.name,
        size: entry.size,
        contentType:
          typeof entry.contentType === "string" ? entry.contentType : undefined,
        readOnly: entry.perm === "ro",
      };
    });
  }

  async read(space: SpaceId, path: string): Promise<FileSnapshot | null> {
    const response = await this.request(space, path, {
      headers: { Accept: "application/octet-stream" },
    });
    if (response.status === 404) return null;
    const revision =
      response.headers.get("X-Content-Revision") ?? response.headers.get("ETag");
    if (!revision || !/^"[^"\r\n]+"$/.test(revision)) {
      throw new Error("The server did not supply a usable content revision.");
    }
    const bytes = await this.bytes(response);
    const result: FileSnapshot = {
      space,
      path,
      revision,
      bytes,
      size: bytes.byteLength,
      contentType: response.headers.get("Content-Type") ?? undefined,
      readOnly: response.headers.get("X-Perm") === "ro",
    };
    if (path.endsWith(".md"))
      result.text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return result;
  }

  async write(
    space: SpaceId,
    path: string,
    bytes: Uint8Array,
    policy: WritePolicy,
  ): Promise<FileSnapshot> {
    if (bytes.byteLength > this.maxBytes)
      throw new Error("File exceeds the configured transfer limit.");
    const headers = new Headers({
      "Content-Type": path.endsWith(".md")
        ? "text/markdown; charset=utf-8"
        : "application/octet-stream",
    });
    if ("create" in policy && policy.create === true) headers.set("If-None-Match", "*");
    else if ("revision" in policy && /^"[^"\r\n]+"$/.test(policy.revision))
      headers.set("If-Match", policy.revision);
    else throw new Error("An explicit revision or create-only policy is required.");
    const response = await this.request(space, path, {
      method: "PUT",
      headers,
      body: bytes as BodyInit,
    });
    if (!response.ok) throw new Error("File write did not succeed.");
    const actual = await this.read(space, path);
    if (
      !actual ||
      actual.bytes.length !== bytes.length ||
      actual.bytes.some((byte, index) => byte !== bytes[index])
    ) {
      throw new Error("Destination byte verification failed; originals were retained.");
    }
    return actual;
  }

  async remove(space: SpaceId, path: string, revision: string): Promise<void> {
    if (!/^"[^"\r\n]+"$/.test(revision))
      throw new Error("An exact revision is required for deletion.");
    const response = await this.request(space, path, {
      method: "DELETE",
      headers: { "If-Match": revision },
    });
    if (!response.ok && response.status !== 404)
      throw new Error("Source removal failed.");
    if (await this.read(space, path))
      throw new Error("Source removal could not be verified.");
  }
}
