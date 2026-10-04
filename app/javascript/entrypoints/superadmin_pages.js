import 'chart.js';
import { createApp, h } from 'vue';
import VueDOMPurifyHTML from 'vue-dompurify-html';
import { createSuperAdminI18n } from '../superadmin_pages/i18n';

import PlaygroundIndex from '../superadmin_pages/views/playground/Index.vue';
import DashboardIndex from '../superadmin_pages/views/dashboard/Index.vue';

const ComponentMapping = {
  PlaygroundIndex: PlaygroundIndex,
  DashboardIndex: DashboardIndex,
};

const renderComponent = (componentName, props) => {
  const app = createApp({
    data() {
      return { props: props };
    },
    render() {
      return h(ComponentMapping[componentName], { componentData: this.props });
    },
  });

  app.use(VueDOMPurifyHTML);
  app.use(createSuperAdminI18n(props?.locale));
  app.mount('#app');
};

document.addEventListener('DOMContentLoaded', () => {
  const element = document.getElementById('app');
  if (element) {
    const componentName = element.dataset.componentName;
    const props = JSON.parse(element.dataset.props);
    renderComponent(componentName, props);
  }
});
