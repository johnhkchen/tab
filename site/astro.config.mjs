// @ts-check
import cloudflare from '@astrojs/cloudflare';
import react from '@astrojs/react';
import starlight from '@astrojs/starlight';
import { d1, r2 } from '@emdash-cms/cloudflare';
import { defineConfig } from 'astro/config';
import emdash from 'emdash/astro';

// The public website for Tab, one Cloudflare Worker (wrangler.jsonc):
// - Landing and pricing pages are EmDash pages (D1 + R2), edited at
//   /_emdash/admin and rendered on request by src/pages/index.astro and
//   src/pages/[slug].astro. Seeded from seed/seed.json.
// - Plan prices live in git (src/data/plans.ts), shown by the `plans` block.
// - Docs are Starlight Markdown in git (src/content/docs/docs), prerendered.
export default defineConfig({
	site: 'https://tab.b28.dev',
	output: 'server',
	adapter: cloudflare(),
	integrations: [
		react(),
		emdash({
			database: d1({ binding: 'DB', session: 'auto' }),
			storage: r2({ binding: 'MEDIA' }),
			// No outside calls: no daily npm version check, and no Google Fonts
			// download for the admin (it falls back to system fonts).
			updateCheck: false,
			fonts: false,
			// English-only admin keeps the Worker bundle smaller.
			admin: { locales: ['en'] },
		}),
		starlight({
			title: 'Tab',
			description: 'Keeps the running tab for your house, so nobody has to.',
			// Docs stay static files even though the rest of the site is on-demand.
			prerender: true,
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/johnhkchen/tab' }],
			customCss: [
				'@fontsource-variable/lora',
				'@fontsource-variable/karla',
				'./src/styles/b28-clay.css',
				'./src/styles/fonts.css',
				'./src/styles/starlight.css',
			],
			sidebar: [
				{ label: 'Start here', slug: 'docs' },
				{ label: 'Send Tab your bills', slug: 'docs/reading' },
				{ label: 'Use Tab from Claude', slug: 'docs/claude' },
				{ label: 'Bills, time away, and asking for it', slug: 'docs/bills' },
				{ label: 'Run it yourself', slug: 'docs/self-host' },
				{ label: 'How your privacy is kept', slug: 'docs/privacy' },
			],
		}),
	],
	devToolbar: { enabled: false },
});
