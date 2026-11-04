export type SpaceId = "personal" | "ksp";

export interface SpaceConfig {
  id: SpaceId;
  label: string;
  prefix: string;
}

export interface FileMeta {
  path: string;
  size: number;
  contentType?: string;
  revision?: string;
  readOnly?: boolean;
}

export interface LinkRef {
  from: number;
  to: number;
  target: string;
  label?: string;
  fragment?: string;
  kind: "page" | "document" | "image" | "embed";
  syntax: "wiki" | "markdown";
  targetSpace?: SpaceId;
  ambiguous?: boolean;
  warning?: string;
}

export interface FileSnapshot extends FileMeta {
  space: SpaceId;
  revision: string;
  bytes: Uint8Array;
  text?: string;
  aliases?: string[];
  links?: LinkRef[];
}

export type WritePolicy = { create: true } | { revision: string };

export interface Transport {
  list(space: SpaceId): Promise<FileMeta[]>;
  read(space: SpaceId, path: string): Promise<FileSnapshot | null>;
  write(
    space: SpaceId,
    path: string,
    bytes: Uint8Array,
    policy: WritePolicy,
  ): Promise<FileSnapshot>;
  remove(space: SpaceId, path: string, revision: string): Promise<void>;
}

export interface ParseNode {
  type?: string;
  from?: number;
  to?: number;
  text?: string;
  children?: ParseNode[];
}

export interface MoveConfig {
  spaces: SpaceConfig[];
  maxFiles: number;
  maxBytes: number;
  maxDepth: number;
  sharedThreshold: number;
}

export const DEFAULT_CONFIG: MoveConfig = {
  spaces: [
    { id: "personal", label: "Personal", prefix: "" },
    { id: "ksp", label: "KSP", prefix: "/ksp" },
  ],
  maxFiles: 1000,
  maxBytes: 67108864,
  maxDepth: 2,
  sharedThreshold: 10,
};
