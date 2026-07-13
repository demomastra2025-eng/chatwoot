import { describe, expect, it } from 'vitest';

import {
  UPLOADABLE_FILE_EXTENSIONS,
  UPLOAD_FILE_ACCEPT,
} from './documentUploadTypes';

describe('Captain document upload types', () => {
  it('matches every backend-supported upload extension', () => {
    expect(UPLOADABLE_FILE_EXTENSIONS).toEqual([
      'pdf',
      'docx',
      'doc',
      'odt',
      'rtf',
      'xlsx',
      'xls',
      'html',
      'htm',
      'txt',
      'text',
      'md',
      'markdown',
      'csv',
      'json',
      'xml',
      'yaml',
      'yml',
      'jpg',
      'jpeg',
      'png',
      'webp',
      'gif',
      'heic',
      'heif',
      'tiff',
      'tif',
      'bmp',
    ]);
  });

  it('builds the file input accept contract from the same list', () => {
    expect(UPLOAD_FILE_ACCEPT).toBe(
      UPLOADABLE_FILE_EXTENSIONS.map(extension => `.${extension}`).join(',')
    );
  });
});
