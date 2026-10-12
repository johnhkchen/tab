// The Worker entry: EmDash's Cloudflare handler serves pages, the admin, and its API;
// the scheduled handler runs on the cron in wrangler.jsonc (scheduled publishing, upkeep).
import type { ExportedHandler } from '@cloudflare/workers-types';
import handler, { createScheduledHandler, PluginBridge } from '@emdash-cms/cloudflare/worker';

export { PluginBridge };

export default {
	...handler,
	scheduled: createScheduledHandler(),
} satisfies ExportedHandler;
