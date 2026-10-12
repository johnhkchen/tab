// EmDash's live content collection (boilerplate). Query pages with getEmDashEntry("pages", slug).
import { defineLiveCollection } from 'astro:content';
import { emdashLoader } from 'emdash/runtime';

export const collections = {
	_emdash: defineLiveCollection({ loader: emdashLoader() }),
};
