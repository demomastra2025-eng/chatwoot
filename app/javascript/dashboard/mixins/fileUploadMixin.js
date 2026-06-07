import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import { DirectUpload } from 'activestorage';
import {
  checkFileSizeLimit,
  isFileTypeAllowedForChannel,
  resolveMaximumFileUploadSize,
  resolveConversationUploadLimit,
} from 'shared/helpers/FileHelper';

export default {
  computed: {
    ...mapGetters({
      accountId: 'getCurrentAccountId',
    }),
    installationLimit() {
      return resolveMaximumFileUploadSize(
        this.globalConfig.maximumFileUploadSize
      );
    },
  },

  methods: {
    maxSizeFor(mime) {
      return resolveConversationUploadLimit({
        channelType: this.inbox?.channel_type,
        medium: this.inbox?.medium,
        mime,
        installationLimit: this.installationLimit,
        isPrivateNote: this.isOnPrivateNote,
      });
    },
    alertOverLimit(maxSizeMB) {
      useAlert(
        this.$t('CONVERSATION.FILE_SIZE_LIMIT', {
          MAXIMUM_SUPPORTED_FILE_UPLOAD_SIZE: maxSizeMB,
        })
      );
    },
    fileForValidation(file) {
      return file?.file || file;
    },
    alertUnsupportedFileType(file) {
      const uploadFile = this.fileForValidation(file);
      useAlert(
        this.$t('CONVERSATION.FILE_TYPE_NOT_SUPPORTED', {
          fileName: uploadFile?.name || file?.name || '',
        })
      );
    },
    isUploadFileTypeAllowed(file) {
      return isFileTypeAllowedForChannel(file, {
        channelType: this.channelType || this.inbox?.channel_type,
        medium: this.inbox?.medium,
        conversationType: this.conversationType,
        isInstagramChannel: this.isAnInstagramChannel,
        isOnPrivateNote: this.isOnPrivateNote,
      });
    },
    onFileUpload(file) {
      if (this.globalConfig.directUploadsEnabled) {
        this.onDirectFileUpload(file);
      } else {
        this.onIndirectFileUpload(file);
      }
    },

    onDirectFileUpload(file) {
      if (!file) return;

      if (!this.isUploadFileTypeAllowed(file)) {
        this.alertUnsupportedFileType(file);
        return;
      }

      const mime = file.file?.type || file.type;
      const maxSizeMB = this.maxSizeFor(mime);

      if (!checkFileSizeLimit(file, maxSizeMB)) {
        this.alertOverLimit(maxSizeMB);
        return;
      }

      const upload = new DirectUpload(
        file.file,
        `/api/v1/accounts/${this.accountId}/conversations/${this.currentChat.id}/direct_uploads`,
        {
          directUploadWillCreateBlobWithXHR: xhr => {
            xhr.setRequestHeader(
              'api_access_token',
              this.currentUser.access_token
            );
          },
        }
      );

      upload.create((error, blob) => {
        if (error) {
          useAlert(error);
        } else {
          this.attachFile({ file, blob });
        }
      });
    },

    onIndirectFileUpload(file) {
      if (!file) return;

      if (!this.isUploadFileTypeAllowed(file)) {
        this.alertUnsupportedFileType(file);
        return;
      }

      const mime = file.file?.type || file.type;
      const maxSizeMB = this.maxSizeFor(mime);

      if (!checkFileSizeLimit(file, maxSizeMB)) {
        this.alertOverLimit(maxSizeMB);
        return;
      }

      this.attachFile({ file });
    },
  },
};
