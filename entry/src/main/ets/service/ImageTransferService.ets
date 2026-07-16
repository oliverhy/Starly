import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface EncodedImage {
  dataUrl: string;
  mimeType: string;
  byteLength: number;
}

const MAX_IMAGE_BYTES: number = 6 * 1024 * 1024;
const MAX_IMAGE_DIMENSION: number = 2048;

class ImageTransferService {
  async pickImage(): Promise<string | null> {
    const picker = new photoAccessHelper.PhotoViewPicker();
    const result = await picker.select({
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1,
      isPhotoTakingSupported: true,
      isOriginalSupported: false
    });
    if (result.photoUris.length === 0) {
      return null;
    }
    return result.photoUris[0];
  }

  async encodeImage(uri: string): Promise<EncodedImage> {
    // Photo picker URIs carry temporary access. Opening the URI first and
    // decoding from its file descriptor avoids ImageSource waiting forever on
    // some devices when a media-library URI is passed directly.
    const selectedFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const source = image.createImageSource(selectedFile.fd);
      if (source === undefined) {
        throw new Error('无法读取所选图片');
      }
      try {
        const info = await source.getImageInfo();
        const originalWidth = Math.max(1, info.size.width);
        const originalHeight = Math.max(1, info.size.height);
        const largestSide = Math.max(originalWidth, originalHeight);
        const scale = largestSide > MAX_IMAGE_DIMENSION ? MAX_IMAGE_DIMENSION / largestSide : 1;
        const pixelMap = await source.createPixelMap({
          desiredSize: {
            width: Math.max(1, Math.round(originalWidth * scale)),
            height: Math.max(1, Math.round(originalHeight * scale))
          }
        });
        const packer = image.createImagePacker();
        try {
          const packed = await packer.packToData(pixelMap, {
            format: 'image/jpeg',
            quality: 78,
            bufferSize: MAX_IMAGE_BYTES
          });
          if (packed.byteLength > MAX_IMAGE_BYTES) {
            throw new Error('图片压缩后仍超过 6 MB，请选择较小的图片');
          }
          const base64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(packed));
          return {
            dataUrl: `data:image/jpeg;base64,${base64}`,
            mimeType: 'image/jpeg',
            byteLength: packed.byteLength
          };
        } finally {
          await packer.release();
          await pixelMap.release();
        }
      } finally {
        await source.release();
      }
    } finally {
      fileIo.closeSync(selectedFile);
    }
  }
}

export default new ImageTransferService();
