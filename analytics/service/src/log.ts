export type Log = (message: string, error: unknown) => void;

function reason(error: unknown): string {
  return error instanceof Error ? `${error.name}: ${error.message}` : String(error);
}

export function logger(scope: string): Log {
  return (message, error) => console.error(`${scope}: ${message}: ${reason(error)}`);
}
