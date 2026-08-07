import axios from 'axios';
import {
  uploadExternalImage,
  uploadFile,
  uploadWhatsAppTemplateMedia,
} from '../uploadHelper';

global.axios = axios;
vi.mock('axios');

describe('Upload Helpers', () => {
  afterEach(() => {
    axios.post.mockReset();
  });

  describe('uploadFile', () => {
    it('should send a POST request with correct data', async () => {
      const mockFile = new File(['dummy content'], 'example.png', {
        type: 'image/png',
      });
      const mockResponse = {
        data: {
          file_url: 'https://example.com/fileUrl',
          blob_key: 'blobKey123',
          blob_id: 'blobId456',
        },
      };

      axios.post.mockResolvedValueOnce(mockResponse);

      const result = await uploadFile(mockFile, '1602');

      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/accounts/1602/upload',
        expect.any(FormData),
        { headers: { 'Content-Type': 'multipart/form-data' } }
      );

      expect(result).toEqual({
        fileUrl: 'https://example.com/fileUrl',
        blobKey: 'blobKey123',
        blobId: 'blobId456',
      });
    });

    it('should handle errors', async () => {
      const mockFile = new File(['dummy content'], 'example.png', {
        type: 'image/png',
      });
      const mockError = new Error('Failed to upload');

      axios.post.mockRejectedValueOnce(mockError);

      await expect(uploadFile(mockFile)).rejects.toThrow('Failed to upload');
    });

    it('adds WhatsApp template validation metadata', async () => {
      const mockFile = new File(['image'], 'example.png', {
        type: 'image/png',
      });
      axios.post.mockResolvedValueOnce({
        data: {
          file_url: 'https://example.com/fileUrl',
          blob_id: 'blobId456',
        },
      });

      await uploadWhatsAppTemplateMedia(mockFile, 'image', '1602');

      const formData = axios.post.mock.calls[0][1];
      expect(formData.get('attachment')).toBe(mockFile);
      expect(formData.get('upload_purpose')).toBe('whatsapp_template_media');
      expect(formData.get('media_type')).toBe('image');
    });
  });

  describe('uploadExternalImage', () => {
    it('should send a POST request with correct data', async () => {
      const mockUrl = 'https://example.com/image.jpg';
      const mockResponse = {
        data: {
          file_url: 'https://example.com/fileUrl',
          blob_key: 'blobKey123',
          blob_id: 'blobId456',
        },
      };

      axios.post.mockResolvedValueOnce(mockResponse);

      const result = await uploadExternalImage(mockUrl, '1602');

      expect(axios.post).toHaveBeenCalledWith(
        '/api/v1/accounts/1602/upload',
        { external_url: mockUrl },
        { headers: { 'Content-Type': 'application/json' } }
      );

      expect(result).toEqual({
        fileUrl: 'https://example.com/fileUrl',
        blobKey: 'blobKey123',
        blobId: 'blobId456',
      });
    });

    it('should handle errors', async () => {
      const mockUrl = 'https://example.com/image.jpg';
      const mockError = new Error('Failed to upload');

      axios.post.mockRejectedValueOnce(mockError);

      await expect(uploadExternalImage(mockUrl)).rejects.toThrow(
        'Failed to upload'
      );
    });
  });
});
