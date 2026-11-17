# Dashboard

A live web dashboard for a game: players online, trade outcomes and wait times, activity per event,
and the live events, refreshed every 5 s over 15 minutes to 24 hours.

## How it works

Next.js 16 (React 19, Tailwind 4, Recharts). The page polls `/api/dashboard`, which reads the
analytics stats API and the live events service on the server, so tokens never reach the browser.
Without a configured analytics service it shows generated demo data and says so at the top.

## Run it

```bash
npm install
npm run dev
```

Open http://localhost:3000. For live data, copy `.env.example` to `.env.local` and fill it from the
`infra/.env` of the analytics project (`ANALYTICS_READ_TOKEN`) and of the live events project
(`EVENTS_ADMIN_TOKEN` as `EVENTS_READ_TOKEN`), after `mise run up` in each.
