import { defineConfig } from 'histoire';
import { HstVue } from '@histoire/plugin-vue';

export default defineConfig({
  setupFile: './histoire.setup.ts',
  plugins: [HstVue()],
  collectMaxThreads: 4,
  vite: {
    server: {
      port: 6179,
    },
  },
  viteIgnorePlugins: ['vite-plugin-ruby'],
  theme: {
    darkClass: 'dark',
    title: '@onelink/design',
    logo: {
      square: '/brand-assets/logo_thumbnail.svg',
      light: '/brand-assets/logo.svg',
      dark: '/brand-assets/logo_dark.svg',
    },
  },
  defaultStoryProps: {
    icon: 'carbon:cube',
    iconColor: '#1A1A1A',
    layout: {
      type: 'grid',
      width: '80%',
    },
  },
  tree: {
    groups: [
      {
        id: 'top',
        title: '',
      },
      {
        id: 'components',
        title: 'Components',
        include: () => true,
      },
    ],
  },
});
