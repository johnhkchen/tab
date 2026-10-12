// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// The public website for Tab: landing and pricing pages (src/pages) plus
// Starlight docs under /docs (src/content/docs/docs). Builds to static files
// in dist/, served by Cloudflare Workers (wrangler.jsonc).
export default defineConfig({
	site: 'https://tab.b28.dev',
	integrations: [
		starlight({
			title: 'Tab',
			description: 'Keeps the running tab for your house, so nobody has to.',
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
				{ label: 'Run it yourself', slug: 'docs/self-host' },
				{ label: 'How your privacy is kept', slug: 'docs/privacy' },
			],
		}),
	],
});
