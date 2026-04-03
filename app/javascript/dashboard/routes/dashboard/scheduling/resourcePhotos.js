export const getResourceDisplayPhoto = (resource = {}, linkedUser = null) => {
  return resource.photoUrl || linkedUser?.thumbnail || '';
};

export const getEditableResourcePhotoUrl = (resource = {}) => {
  return resource.photoUrl || '';
};
