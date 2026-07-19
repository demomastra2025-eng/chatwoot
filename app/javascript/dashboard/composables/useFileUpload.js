import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { DirectUpload } from 'activestorage';
import {
  checkFileSizeLimit,
  isFileTypeAllowedForChannel,
  resolveMaximumFileUploadSize,
  resolveConversationUploadLimit,
} from 'shared/helpers/FileHelper';

/**
 * Composable for handling file uploads in conversations
 * @param {Object} options
 * @param {Object} options.inbox - Current inbox object (has channel_type, medium, etc.)
 * @param {Function} options.attachFile - Callback to handle file attachment
 * @param {Function} options.onUploadStart - Optional callback after validation
 * @param {Function} options.onUploadEnd - Optional callback after upload/attachment completion
 * @param {boolean} options.isPrivateNote - Whether the upload is for a private note
 */
export const useFileUpload = ({
  inbox,
  attachFile,
  onUploadStart = () => {},
  onUploadEnd = () => {},
  isPrivateNote = false,
}) => {
  const { t } = useI18n();

  const accountId = useMapGetter('getCurrentAccountId');
  const currentUser = useMapGetter('getCurrentUser');
  const currentChat = useMapGetter('getSelectedChat');
  const globalConfig = useMapGetter('globalConfig/get');

  const installationLimit = resolveMaximumFileUploadSize(
    globalConfig.value?.maximumFileUploadSize
  );

  // helper: compute max upload size for a given file's mime
  const maxSizeFor = mime => {
    return resolveConversationUploadLimit({
      channelType: inbox?.channel_type,
      medium: inbox?.medium,
      mime,
      installationLimit,
      isPrivateNote,
    });
  };

  const alertOverLimit = maxSizeMB =>
    useAlert(
      t('CONVERSATION.FILE_SIZE_LIMIT', {
        MAXIMUM_SUPPORTED_FILE_UPLOAD_SIZE: maxSizeMB,
      })
    );

  const alertUnsupportedFileType = file => {
    const uploadFile = file?.file || file;
    useAlert(
      t('CONVERSATION.FILE_TYPE_NOT_SUPPORTED', {
        fileName: uploadFile?.name || file?.name || '',
      })
    );
  };

  const isUploadFileTypeAllowed = file =>
    isFileTypeAllowedForChannel(file, {
      channelType: inbox?.channel_type,
      medium: inbox?.medium,
      isOnPrivateNote: isPrivateNote,
    });

  const attachFileAndFinish = payload => {
    try {
      const result = attachFile(payload);
      Promise.resolve(result).then(onUploadEnd, onUploadEnd);
    } catch (error) {
      onUploadEnd();
      throw error;
    }
  };

  const handleDirectFileUpload = file => {
    if (!file) return;

    if (!isUploadFileTypeAllowed(file)) {
      alertUnsupportedFileType(file);
      return;
    }

    const mime = file.file?.type || file.type;
    const maxSizeMB = maxSizeFor(mime);

    if (!checkFileSizeLimit(file, maxSizeMB)) {
      alertOverLimit(maxSizeMB);
      return;
    }

    onUploadStart();

    const upload = new DirectUpload(
      file.file,
      `/api/v1/accounts/${accountId.value}/conversations/${currentChat.value.id}/direct_uploads`,
      {
        directUploadWillCreateBlobWithXHR: xhr => {
          xhr.setRequestHeader(
            'api_access_token',
            currentUser.value.access_token
          );
        },
      }
    );

    upload.create((error, blob) => {
      if (error) {
        useAlert(error);
        onUploadEnd();
      } else {
        attachFileAndFinish({ file, blob });
      }
    });
  };

  const handleIndirectFileUpload = file => {
    if (!file) return;

    if (!isUploadFileTypeAllowed(file)) {
      alertUnsupportedFileType(file);
      return;
    }

    const mime = file.file?.type || file.type;
    const maxSizeMB = maxSizeFor(mime);

    if (!checkFileSizeLimit(file, maxSizeMB)) {
      alertOverLimit(maxSizeMB);
      return;
    }

    onUploadStart();
    attachFileAndFinish({ file });
  };

  const onFileUpload = file => {
    if (globalConfig.value.directUploadsEnabled) {
      handleDirectFileUpload(file);
    } else {
      handleIndirectFileUpload(file);
    }
  };

  return { onFileUpload };
};
