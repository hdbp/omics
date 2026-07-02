let nextId = 1;

export function makeId(prefix: string): string {
  return `${prefix}-${nextId++}-${Date.now().toString(36)}`;
}
