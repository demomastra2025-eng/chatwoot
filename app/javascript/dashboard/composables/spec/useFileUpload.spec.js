import { useFileUpload } from '../useFileUpload';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { DirectUpload } from 'activestorage';
import {
  checkFileSizeLimit,
  isFileTypeAllowedForChannel,
  resolveConversationUploadLimit,
} from 'shared/helpers/FileHelper';

vi.mock('dashboard/composables/store');
vi.mock('dashboard/composables', () => ({
  useAlert: vi.fn(message => message),
}));
vi.mock('vue-i18n');
vi.mock('activestorage');
vi.mock('shared/helpers/FileHelper', () => ({
  checkFileSizeLimit: vi.fn(),
  isFileTypeAllowedForChannel: vi.fn(),
  resolveMaximumFileUploadSize: vi.fn(value => Number(value) || 40),
  resolveConversationUploadLimit: vi.fn(),
  DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE: 40,
}));

describe('useFileUpload', () => {
  const mockAttachFile = vi.fn();
  const mockTranslate = vi.fn();

  const mockFile = {
    file: new File(['test'], 'test.jpg', { type: 'image/jpeg' }),
  };

  const inbox = {
    channel_type: 'Channel::WhatsApp',
    medium: 'whatsapp',
  };

  beforeEach(() => {
    vi.clearAllMocks();

    useMapGetter.mockImplementation(getter => {
      const getterMap = {
        getCurrentAccountId: { value: '123' },
        getCurrentUser: { value: { access_token: 'test-token' } },
        getSelectedChat: { value: { id: '456' } },
        'globalConfig/get': {
          value: { directUploadsEnabled: true, maximumFileUploadSize: 40 },
        },
      };
      return getterMap[getter];
    });

    useI18n.mockReturnValue({ t: mockTranslate });
    checkFileSizeLimit.mockReturnValue(true);
    isFileTypeAllowedForChannel.mockReturnValue(true);
    resolveConversationUploadLimit.mockReturnValue(25);
  });

  it('handles direct file upload when direct uploads enabled', () => {
    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    const mockBlob = { signed_id: 'test-blob' };
    DirectUpload.mockImplementation(() => ({
      create: callback => callback(null, mockBlob),
    }));

    onFileUpload(mockFile);

    // size rules called with inbox + mime
    expect(resolveConversationUploadLimit).toHaveBeenCalledWith({
      channelType: inbox.channel_type,
      medium: inbox.medium,
      mime: 'image/jpeg',
      installationLimit: 40,
      isPrivateNote: false,
    });

    // size check called with max from helper
    expect(checkFileSizeLimit).toHaveBeenCalledWith(mockFile, 25);

    expect(DirectUpload).toHaveBeenCalledWith(
      mockFile.file,
      '/api/v1/accounts/123/conversations/456/direct_uploads',
      expect.any(Object)
    );
    expect(mockAttachFile).toHaveBeenCalledWith({
      file: mockFile,
      blob: mockBlob,
    });
  });

  it('handles indirect file upload when direct upload disabled', () => {
    useMapGetter.mockImplementation(getter => {
      const getterMap = {
        getCurrentAccountId: { value: '123' },
        getCurrentUser: { value: { access_token: 'test-token' } },
        getSelectedChat: { value: { id: '456' } },
        'globalConfig/get': {
          value: { directUploadsEnabled: false, maximumFileUploadSize: 40 },
        },
      };
      return getterMap[getter];
    });

    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    onFileUpload(mockFile);

    expect(DirectUpload).not.toHaveBeenCalled();
    expect(resolveConversationUploadLimit).toHaveBeenCalled();
    expect(checkFileSizeLimit).toHaveBeenCalledWith(mockFile, 25);
    expect(mockAttachFile).toHaveBeenCalledWith({ file: mockFile });
  });

  it('shows alert when file size exceeds limit', () => {
    checkFileSizeLimit.mockReturnValue(false);
    mockTranslate.mockReturnValue('File size exceeds limit');

    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    onFileUpload(mockFile);

    expect(useAlert).toHaveBeenCalledWith('File size exceeds limit');
    expect(mockAttachFile).not.toHaveBeenCalled();
  });

  it('shows alert and skips upload for unsupported file types', () => {
    isFileTypeAllowedForChannel.mockReturnValue(false);
    mockTranslate.mockReturnValue('Unsupported file type');

    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    onFileUpload(mockFile);

    expect(useAlert).toHaveBeenCalledWith('Unsupported file type');
    expect(checkFileSizeLimit).not.toHaveBeenCalled();
    expect(DirectUpload).not.toHaveBeenCalled();
    expect(mockAttachFile).not.toHaveBeenCalled();
  });

  it('uses per-mime limits from helper', () => {
    resolveConversationUploadLimit.mockImplementation(({ mime }) =>
      mime.startsWith('image/') ? 10 : 50
    );
    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    DirectUpload.mockImplementation(() => ({
      create: cb => cb(null, { signed_id: 'blob' }),
    }));

    onFileUpload(mockFile);

    expect(resolveConversationUploadLimit).toHaveBeenCalledWith({
      channelType: inbox.channel_type,
      medium: inbox.medium,
      mime: 'image/jpeg',
      installationLimit: 40,
      isPrivateNote: false,
    });
    expect(checkFileSizeLimit).toHaveBeenCalledWith(mockFile, 10);
  });

  it('allows WhatsApp videos up to 70 MB', () => {
    const videoFile = {
      file: new File(['video'], 'video.mp4', { type: 'video/mp4' }),
    };
    resolveConversationUploadLimit.mockReturnValue(70);

    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    onFileUpload(videoFile);

    expect(resolveConversationUploadLimit).toHaveBeenCalledWith({
      channelType: inbox.channel_type,
      medium: inbox.medium,
      mime: 'video/mp4',
      installationLimit: 40,
      isPrivateNote: false,
    });
    expect(checkFileSizeLimit).toHaveBeenCalledWith(videoFile, 70);
  });

  it('handles direct upload errors', () => {
    const mockError = 'Upload failed';
    DirectUpload.mockImplementation(() => ({
      create: callback => callback(mockError, null),
    }));

    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    onFileUpload(mockFile);

    expect(useAlert).toHaveBeenCalledWith(mockError);
    expect(mockAttachFile).not.toHaveBeenCalled();
  });

  it('does nothing when file is null', () => {
    const { onFileUpload } = useFileUpload({
      inbox,
      attachFile: mockAttachFile,
    });

    onFileUpload(null);

    expect(checkFileSizeLimit).not.toHaveBeenCalled();
    expect(resolveConversationUploadLimit).not.toHaveBeenCalled();
    expect(mockAttachFile).not.toHaveBeenCalled();
    expect(useAlert).not.toHaveBeenCalled();
  });
});
