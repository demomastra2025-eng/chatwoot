import ChatAttachment from './ChatAttachment.vue';
import { DirectUpload } from 'activestorage';
import {
  checkFileSizeLimit,
  isFileTypeAllowedForChannel,
} from 'shared/helpers/FileHelper';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';

vi.mock('activestorage', () => ({
  DirectUpload: vi.fn(),
}));

vi.mock('shared/helpers/FileHelper', () => ({
  checkFileSizeLimit: vi.fn(),
  isFileTypeAllowedForChannel: vi.fn(),
  resolveMaximumFileUploadSize: vi.fn(value => Number(value) || 40),
}));

vi.mock('shared/helpers/mitt', () => ({
  emitter: {
    emit: vi.fn(),
  },
}));

vi.mock('../composables/useAttachments', () => ({
  useAttachments: () => ({ canHandleAttachments: true }),
}));

const buildContext = () => ({
  isUploading: false,
  fileUploadSizeLimit: 40,
  onAttach: vi.fn(),
  $t: vi.fn((key, params = {}) => `${key}:${params.fileName || ''}`),
  getLocalFileAttributes: vi.fn(() => ({
    thumbUrl: 'blob:url',
    fileType: 'file',
  })),
  alertUnsupportedFileType: ChatAttachment.methods.alertUnsupportedFileType,
  isUploadFileTypeAllowed: ChatAttachment.methods.isUploadFileTypeAllowed,
});

const buildUploadFile = ({ name, type }) => ({
  name,
  type,
  size: 1000,
  file: new File(['certificate'], name, { type }),
});

describe('ChatAttachment', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    checkFileSizeLimit.mockReturnValue(true);
    isFileTypeAllowedForChannel.mockReturnValue(true);
  });

  it('passes website-widget uploads through paired file type validation', () => {
    const uploadFile = buildUploadFile({
      name: 'company-signing.pfx',
      type: 'application/x-pkcs12',
    });

    expect(
      ChatAttachment.methods.isUploadFileTypeAllowed.call({}, uploadFile)
    ).toBe(true);
    expect(isFileTypeAllowedForChannel).toHaveBeenCalledWith(uploadFile, {
      channelType: 'Channel::WebWidget',
    });
  });

  it('blocks unsupported indirect uploads before attach', async () => {
    const context = buildContext();
    const uploadFile = buildUploadFile({
      name: 'company-signing.pfx',
      type: 'application/xml',
    });
    isFileTypeAllowedForChannel.mockReturnValue(false);

    await ChatAttachment.methods.onIndirectFileUpload.call(context, uploadFile);

    expect(emitter.emit).toHaveBeenCalledWith(BUS_EVENTS.SHOW_ALERT, {
      message: 'FILE_TYPE_NOT_SUPPORTED:company-signing.pfx',
    });
    expect(checkFileSizeLimit).not.toHaveBeenCalled();
    expect(context.onAttach).not.toHaveBeenCalled();
    expect(context.isUploading).toBe(false);
  });

  it('blocks unsupported direct uploads before ActiveStorage upload', async () => {
    const context = buildContext();
    const uploadFile = buildUploadFile({
      name: 'company-signing.bin',
      type: 'application/x-pkcs12',
    });
    isFileTypeAllowedForChannel.mockReturnValue(false);

    await ChatAttachment.methods.onDirectFileUpload.call(context, uploadFile);

    expect(emitter.emit).toHaveBeenCalledWith(BUS_EVENTS.SHOW_ALERT, {
      message: 'FILE_TYPE_NOT_SUPPORTED:company-signing.bin',
    });
    expect(checkFileSizeLimit).not.toHaveBeenCalled();
    expect(DirectUpload).not.toHaveBeenCalled();
  });
});
