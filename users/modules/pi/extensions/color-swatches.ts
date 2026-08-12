import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Markdown, Text } from "@earendil-works/pi-tui";

type RGB = { r: number; g: number; b: number };
type MarkdownInstance = { text: string };
type TextInstance = { text: string };
type MarkdownRender = (this: Markdown, width: number) => string[];
type TextRender = (this: Text, width: number) => string[];
type PatchState = { originalRender: MarkdownRender; references: number };
type TextPatchState = { originalRender: TextRender; references: number };

const PATCH_KEY = Symbol.for("pi.extension.color-swatches.markdown-patch");
const TEXT_PATCH_KEY = Symbol.for("pi.extension.color-swatches.text-patch");
const COLOR_PATTERN = /#[0-9a-f]{8}\b|#[0-9a-f]{6}\b|#[0-9a-f]{4}\b|#[0-9a-f]{3}\b|\b0x[0-9a-f]{6}\b|\brgba?\([^\n)]*\)|\bhsla?\([^\n)]*\)|\bhsva?\([^\n)]*\)|\bhwb\([^\n)]*\)|\bcolor\(\s*srgb\s+[^\n)]*\)/gi;

const clamp = (value: number, minimum = 0, maximum = 255): number =>
	Math.min(maximum, Math.max(minimum, value));

function parseNumber(value: string): number | undefined {
	const parsed = Number.parseFloat(value);
	return Number.isFinite(parsed) ? parsed : undefined;
}

function parseRgbChannel(value: string): number | undefined {
	const parsed = parseNumber(value);
	if (parsed === undefined) return undefined;
	return clamp(value.trim().endsWith("%") ? (parsed / 100) * 255 : parsed);
}

function parseUnitChannel(value: string): number | undefined {
	const parsed = parseNumber(value);
	if (parsed === undefined) return undefined;
	return clamp(value.trim().endsWith("%") ? parsed / 100 : parsed, 0, 1);
}

function parseAngle(value: string): number | undefined {
	const parsed = parseNumber(value);
	if (parsed === undefined) return undefined;
	const normalized = value.trim().toLowerCase();
	let degrees = parsed;
	if (normalized.endsWith("turn")) degrees = parsed * 360;
	else if (normalized.endsWith("rad")) degrees = (parsed * 180) / Math.PI;
	else if (normalized.endsWith("grad")) degrees = parsed * 0.9;
	return ((degrees % 360) + 360) % 360;
}

function functionParts(value: string): string[] {
	const open = value.indexOf("(");
	const inner = value.slice(open + 1, -1).replace(/,/g, " ");
	return inner.split("/")[0]!.trim().split(/\s+/).filter(Boolean);
}

function hueToRgb(hue: number, saturation: number, lightness: number): RGB {
	const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation;
	const section = hue / 60;
	const x = chroma * (1 - Math.abs((section % 2) - 1));
	let r = 0;
	let g = 0;
	let b = 0;
	if (section < 1) [r, g] = [chroma, x];
	else if (section < 2) [r, g] = [x, chroma];
	else if (section < 3) [g, b] = [chroma, x];
	else if (section < 4) [g, b] = [x, chroma];
	else if (section < 5) [r, b] = [x, chroma];
	else [r, b] = [chroma, x];
	const match = lightness - chroma / 2;
	return {
		r: clamp(Math.round((r + match) * 255)),
		g: clamp(Math.round((g + match) * 255)),
		b: clamp(Math.round((b + match) * 255)),
	};
}

function parseHex(value: string): RGB | undefined {
	let hex = value.startsWith("#") ? value.slice(1) : value.slice(2);
	if (hex.length === 3 || hex.length === 4) hex = hex.split("").map((part) => part + part).join("");
	if (hex.length !== 6 && hex.length !== 8) return undefined;
	const numeric = Number.parseInt(hex.slice(0, 6), 16);
	if (!Number.isFinite(numeric)) return undefined;
	return { r: (numeric >> 16) & 255, g: (numeric >> 8) & 255, b: numeric & 255 };
}

function parseColor(value: string): RGB | undefined {
	const lower = value.toLowerCase();
	if (lower.startsWith("#") || lower.startsWith("0x")) return parseHex(lower);

	const parts = functionParts(lower);
	if (lower.startsWith("rgb")) {
		if (parts.length < 3) return undefined;
		const channels = parts.slice(0, 3).map(parseRgbChannel);
		if (channels.some((channel) => channel === undefined)) return undefined;
		return { r: Math.round(channels[0]!), g: Math.round(channels[1]!), b: Math.round(channels[2]!) };
	}

	if (lower.startsWith("hsl")) {
		if (parts.length < 3) return undefined;
		const hue = parseAngle(parts[0]!);
		const saturation = parseUnitChannel(parts[1]!);
		const lightness = parseUnitChannel(parts[2]!);
		if (hue === undefined || saturation === undefined || lightness === undefined) return undefined;
		return hueToRgb(hue, saturation, lightness);
	}

	if (lower.startsWith("hsv")) {
		if (parts.length < 3) return undefined;
		const hue = parseAngle(parts[0]!);
		const saturation = parseUnitChannel(parts[1]!);
		const valueChannel = parseUnitChannel(parts[2]!);
		if (hue === undefined || saturation === undefined || valueChannel === undefined) return undefined;
		const lightness = valueChannel * (1 - saturation / 2);
		const hslSaturation = lightness === 0 || lightness === 1
			? 0
			: (valueChannel - lightness) / Math.min(lightness, 1 - lightness);
		return hueToRgb(hue, hslSaturation, lightness);
	}

	if (lower.startsWith("hwb")) {
		if (parts.length < 3) return undefined;
		const hue = parseAngle(parts[0]!);
		let white = parseUnitChannel(parts[1]!);
		let black = parseUnitChannel(parts[2]!);
		if (hue === undefined || white === undefined || black === undefined) return undefined;
		if (white + black > 1) {
			const total = white + black;
			white /= total;
			black /= total;
		}
		const pure = hueToRgb(hue, 1, 0.5);
		const factor = 1 - white - black;
		return {
			r: Math.round((pure.r / 255) * factor * 255 + white * 255),
			g: Math.round((pure.g / 255) * factor * 255 + white * 255),
			b: Math.round((pure.b / 255) * factor * 255 + white * 255),
		};
	}

	if (lower.startsWith("color(")) {
		const srgbParts = lower.slice(lower.indexOf("srgb") + 4, -1).split("/")[0]!.trim().split(/\s+/);
		if (srgbParts.length < 3) return undefined;
		const channels = srgbParts.slice(0, 3).map(parseUnitChannel);
		if (channels.some((channel) => channel === undefined)) return undefined;
		return { r: Math.round(channels[0]! * 255), g: Math.round(channels[1]! * 255), b: Math.round(channels[2]! * 255) };
	}

	return undefined;
}

function swatch(value: string, color: RGB): string {
	const luminance = (0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b) / 255;
	const foreground = luminance > 0.56 ? "0;0;0" : "255;255;255";
	return `\x1b[48;2;${color.r};${color.g};${color.b}m\x1b[38;2;${foreground}m${value}\x1b[39m\x1b[49m`;
}

function colorize(text: string): string {
	return text.replace(COLOR_PATTERN, (value) => {
		const color = parseColor(value);
		return color ? swatch(value, color) : value;
	});
}

export default function (pi: ExtensionAPI) {
	const markdownPrototype = Markdown.prototype as typeof Markdown.prototype & Record<symbol, PatchState | undefined>;
	let markdownState = markdownPrototype[PATCH_KEY];
	if (!markdownState) {
		const originalRender = markdownPrototype.render as MarkdownRender;
		markdownState = { originalRender, references: 0 };
		markdownPrototype[PATCH_KEY] = markdownState;
		markdownPrototype.render = function (width: number): string[] {
			const instance = this as unknown as MarkdownInstance;
			const originalText = instance.text;
			instance.text = colorize(originalText);
			try {
				return originalRender.call(this, width);
			} finally {
				instance.text = originalText;
			}
		};
	}
	markdownState.references += 1;

	const textPrototype = Text.prototype as typeof Text.prototype & Record<symbol, TextPatchState | undefined>;
	let textState = textPrototype[TEXT_PATCH_KEY];
	if (!textState) {
		const originalRender = textPrototype.render as TextRender;
		textState = { originalRender, references: 0 };
		textPrototype[TEXT_PATCH_KEY] = textState;
		textPrototype.render = function (width: number): string[] {
			const instance = this as unknown as TextInstance;
			const originalText = instance.text;
			instance.text = colorize(originalText);
			try {
				return originalRender.call(this, width);
			} finally {
				instance.text = originalText;
			}
		};
	}
	textState.references += 1;

	let released = false;
	pi.on("session_shutdown", () => {
		if (released) return;
		released = true;

		const currentMarkdown = markdownPrototype[PATCH_KEY];
		if (currentMarkdown) {
			currentMarkdown.references -= 1;
			if (currentMarkdown.references <= 0) {
				markdownPrototype.render = currentMarkdown.originalRender;
				delete markdownPrototype[PATCH_KEY];
			}
		}

		const currentText = textPrototype[TEXT_PATCH_KEY];
		if (currentText) {
			currentText.references -= 1;
			if (currentText.references <= 0) {
				textPrototype.render = currentText.originalRender;
				delete textPrototype[TEXT_PATCH_KEY];
			}
		}
	});
}
