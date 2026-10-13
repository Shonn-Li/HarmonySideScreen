export const start: (surfaceId: string, port: number) => boolean;
export const stop: () => void;
export const status: () => string;
export const frames: () => number;
export const fps: () => number;
export const running: () => boolean;
export const touch: (x: number, y: number, action: number) => void;
export const viewport: (width: number, height: number, dpiX: number, dpiY: number) => void;
export const orientation: () => number;
export const placement: () => number;
export const place: (side: number, alignment: number) => boolean;

export const diagnostics: () => string;
export const testConnection: () => boolean;
