export type Spend = { session: number; today: number; week: number }

declare module 'claude-code' {
  interface PluginState {
    'session-cost': { spend: Spend | null }
  }
}
