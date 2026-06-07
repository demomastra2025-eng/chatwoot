import {
  DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE,
  WHATSAPP_DOCUMENT_UPLOAD_SIZE,
  WHATSAPP_VIDEO_UPLOAD_SIZE,
  formatBytes,
  fileSizeInMegaBytes,
  checkFileSizeLimit,
  resolveMaximumFileUploadSize,
  resolveConversationUploadLimit,
  withBusinessCertificateFileTypes,
  isFileTypeAllowedForChannel,
} from '../FileHelper';

describe('#File Helpers', () => {
  describe('formatBytes', () => {
    it('should return zero bytes if 0 is passed', () => {
      expect(formatBytes(0)).toBe('0 Bytes');
    });
    it('should return in bytes if 1000 is passed', () => {
      expect(formatBytes(1000)).toBe('1000 Bytes');
    });
    it('should return in KB if 100000 is passed', () => {
      expect(formatBytes(10000)).toBe('9.77 KB');
    });
    it('should return in MB if 10000000 is passed', () => {
      expect(formatBytes(10000000)).toBe('9.54 MB');
    });
  });

  describe('fileSizeInMegaBytes', () => {
    it('should return zero if 0 is passed', () => {
      expect(fileSizeInMegaBytes(0)).toBe(0);
    });
    it('should return 19.07 if 20000000 is passed', () => {
      expect(fileSizeInMegaBytes(20000000)).toBeCloseTo(19.07, 2);
    });
  });

  describe('checkFileSizeLimit', () => {
    it('should return false if file with size 62208194 and file size limit 40 are passed', () => {
      expect(checkFileSizeLimit({ file: { size: 62208194 } }, 40)).toBe(false);
    });
    it('should return true if file with size 62208194 and file size limit 40 are passed', () => {
      expect(checkFileSizeLimit({ file: { size: 199154 } }, 40)).toBe(true);
    });
  });

  describe('resolveMaximumFileUploadSize', () => {
    it('should return default when value is undefined', () => {
      expect(resolveMaximumFileUploadSize(undefined)).toBe(
        DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE
      );
    });

    it('should return default when value is not a positive number', () => {
      expect(resolveMaximumFileUploadSize('not-a-number')).toBe(
        DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE
      );
      expect(resolveMaximumFileUploadSize(-5)).toBe(
        DEFAULT_MAXIMUM_FILE_UPLOAD_SIZE
      );
    });

    it('should parse numeric strings and numbers', () => {
      expect(resolveMaximumFileUploadSize('50')).toBe(50);
      expect(resolveMaximumFileUploadSize(75)).toBe(75);
    });
  });

  describe('resolveConversationUploadLimit', () => {
    it('returns installation limit for private notes', () => {
      expect(
        resolveConversationUploadLimit({
          channelType: 'Channel::Whatsapp',
          medium: 'whatsapp',
          mime: 'video/mp4',
          installationLimit: 40,
          isPrivateNote: true,
        })
      ).toBe(40);
    });

    it('allows WhatsApp videos up to 70 MB', () => {
      expect(
        resolveConversationUploadLimit({
          channelType: 'Channel::Whatsapp',
          medium: 'whatsapp',
          mime: 'video/mp4',
          installationLimit: 40,
        })
      ).toBe(WHATSAPP_VIDEO_UPLOAD_SIZE);
    });

    it('keeps WhatsApp image limit unchanged', () => {
      expect(
        resolveConversationUploadLimit({
          channelType: 'Channel::Whatsapp',
          medium: 'whatsapp',
          mime: 'image/png',
          installationLimit: 40,
        })
      ).toBe(5);
    });

    it('caps larger channel limits by installation limit for non-video files', () => {
      expect(
        resolveConversationUploadLimit({
          channelType: 'Channel::Whatsapp',
          medium: 'whatsapp',
          mime: 'application/pdf',
          installationLimit: 40,
        })
      ).toBe(WHATSAPP_DOCUMENT_UPLOAD_SIZE);
    });
  });

  describe('withBusinessCertificateFileTypes', () => {
    it('adds PFX/P12 accept values when XML documents are allowed', () => {
      expect(
        withBusinessCertificateFileTypes('application/pdf, application/xml')
      ).toContain('application/x-pkcs12');
      expect(
        withBusinessCertificateFileTypes('application/pdf, text/xml')
      ).toContain('.pfx');
    });

    it('keeps restricted channels unchanged when XML documents are not allowed', () => {
      expect(
        withBusinessCertificateFileTypes('image/jpeg, application/pdf')
      ).toBe('image/jpeg, application/pdf');
    });
  });

  describe('isFileTypeAllowedForChannel', () => {
    describe('edge cases', () => {
      it('should return false for null file', () => {
        expect(isFileTypeAllowedForChannel(null)).toBe(false);
      });

      it('should return false for undefined file', () => {
        expect(isFileTypeAllowedForChannel(undefined)).toBe(false);
      });

      it('should return false for file with zero size', () => {
        const file = { name: 'test.png', type: 'image/png', size: 0 };
        expect(isFileTypeAllowedForChannel(file)).toBe(false);
      });
    });

    describe('wildcard MIME types', () => {
      it('should allow image/png when image/* is allowed', () => {
        const file = { name: 'test.png', type: 'image/png', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should allow image/jpeg when image/* is allowed', () => {
        const file = { name: 'test.jpg', type: 'image/jpeg', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should allow audio/mp3 when audio/* is allowed', () => {
        const file = { name: 'test.mp3', type: 'audio/mp3', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should allow video/mp4 when video/* is allowed', () => {
        const file = { name: 'test.mp4', type: 'video/mp4', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });
    });

    describe('exact MIME types', () => {
      it('should allow application/pdf when explicitly allowed', () => {
        const file = { name: 'test.pdf', type: 'application/pdf', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should allow text/plain when explicitly allowed', () => {
        const file = { name: 'test.txt', type: 'text/plain', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should allow XML documents on document-capable channels', () => {
        const file = {
          name: 'invoice.xml',
          type: 'application/xml',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should allow PFX certificates on document-capable channels', () => {
        const file = {
          name: 'company-signing.pfx',
          type: 'application/x-pkcs12',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should reject PFX certificates with a document MIME type', () => {
        const file = {
          name: 'company-signing.pfx',
          type: 'application/xml',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(false);
      });

      it('should reject certificate MIME types without a certificate extension', () => {
        const file = {
          name: 'company-signing.bin',
          type: 'application/x-pkcs12',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(false);
      });
    });

    describe('file extensions', () => {
      it('should allow .3gpp extension when explicitly allowed', () => {
        const file = { name: 'test.3gpp', type: '', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });

      it('should allow .pfx extension when browsers do not provide a MIME type', () => {
        const file = { name: 'company-signing.PFX', type: '', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(true);
      });
    });

    describe('Instagram special handling', () => {
      it('should use Instagram rules when isInstagramChannel is true', () => {
        const file = { name: 'test.png', type: 'image/png', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
            isInstagramChannel: true,
          })
        ).toBe(true);
      });

      it('should use Instagram rules when conversationType is instagram_direct_message', () => {
        const file = { name: 'test.png', type: 'image/png', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
            conversationType: 'instagram_direct_message',
          })
        ).toBe(true);
      });
    });

    describe('disallowed file types', () => {
      it('should reject executable files', () => {
        const file = {
          name: 'malware.exe',
          type: 'application/x-msdownload',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(false);
      });

      it('should reject unsupported file types', () => {
        const file = {
          name: 'test.xyz',
          type: 'application/x-unknown',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::WebWidget',
          })
        ).toBe(false);
      });
    });

    describe('channel-specific rules', () => {
      it('should allow WhatsApp-specific file types', () => {
        const file = { name: 'test.pdf', type: 'application/pdf', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::Whatsapp',
          })
        ).toBe(true);
      });

      it('should not add PFX certificates to restricted WhatsApp channels', () => {
        const file = {
          name: 'company-signing.pfx',
          type: 'application/x-pkcs12',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::Whatsapp',
          })
        ).toBe(false);
      });

      it('should allow Twilio WhatsApp-specific file types', () => {
        const file = { name: 'test.pdf', type: 'application/pdf', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::TwilioSms',
            medium: 'whatsapp',
          })
        ).toBe(true);
      });
    });

    describe('private note file types', () => {
      it('should allow broader file types for private notes', () => {
        const file = {
          name: 'test.pdf',
          type: 'application/pdf',
          size: 1000,
        };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::Line',
            isOnPrivateNote: true,
          })
        ).toBe(true);
      });

      it('should allow CSV files in private notes', () => {
        const file = { name: 'data.csv', type: 'text/csv', size: 1000 };
        expect(
          isFileTypeAllowedForChannel(file, {
            channelType: 'Channel::Line',
            isOnPrivateNote: true,
          })
        ).toBe(true);
      });
    });
  });
});
