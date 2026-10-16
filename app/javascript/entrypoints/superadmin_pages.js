import { createApp, h } from 'vue';
import { createSuperAdminI18n } from '../superadmin_pages/i18n';

import DashboardIndex from '../superadmin_pages/views/dashboard/Index.vue';

const ComponentMapping = {
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

  app.use(createSuperAdminI18n());
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
