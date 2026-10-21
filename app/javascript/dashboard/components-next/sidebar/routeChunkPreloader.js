const preloadedRouteKeys = new Set();

export const preloadRouteComponents = (router, to) => {
  if (!router || !to || typeof router.resolve !== 'function') return;

  try {
    const resolved = router.resolve(to);
    const cacheKey = resolved?.name
      ? String(resolved.name)
      : resolved?.path || '';
    if (!cacheKey || preloadedRouteKeys.has(cacheKey)) return;

    const matchedRecords = Array.isArray(resolved?.matched)
      ? resolved.matched
      : [];
    if (!matchedRecords.length) return;

    preloadedRouteKeys.add(cacheKey);

    matchedRecords.forEach(record => {
      const components = record?.components || {};
      Object.values(components).forEach(component => {
        if (
          typeof component === 'function' &&
          !('__vccOpts' in component) &&
          !component.render &&
          !component.setup
        ) {
          Promise.resolve(component()).catch(() => {
            preloadedRouteKeys.delete(cacheKey);
          });
        }
      });
    });
  } catch {
    // Ignore unresolved routes in isolated unit test mocks
  }
};

export const resolveDefaultMenuItemTarget = item => {
  if (!item) return null;
  if (item.to) return item.to;
  if (!Array.isArray(item.children) || !item.children.length) return null;

  const navigableChildren = item.children.filter(child => child?.to);
  if (!navigableChildren.length) return null;

  if (item.defaultChildName) {
    const defaultChild = navigableChildren.find(
      child => child.name === item.defaultChildName
    );
    if (defaultChild?.to) return defaultChild.to;
  }

  return navigableChildren[0]?.to || null;
};

export const preloadSidebarMenuTargets = (router, menuItems = []) => {
  if (!Array.isArray(menuItems) || !menuItems.length) return;

  menuItems.forEach(item => {
    const target = resolveDefaultMenuItemTarget(item);
    if (target) {
      preloadRouteComponents(router, target);
    }
    if (Array.isArray(item?.children) && item.children.length) {
      preloadSidebarMenuTargets(router, item.children);
    }
  });
};

export const resetPreloadedRouteComponentsForTests = () => {
  preloadedRouteKeys.clear();
};
