// Crops the picture to a centered 16:9 rectangle, shrinks it and re-encodes it as a
// JPEG (which also drops EXIF data). Stays under the server's size limit.
export const BANNER_MAX_BYTES = 300 * 1024

export async function resizeBannerToJpeg(file: File, width = 960, height = 540): Promise<Blob> {
  const bitmap = await createImageBitmap(file)
  const ratio = width / height
  const wide = bitmap.width / bitmap.height > ratio
  const sw = wide ? bitmap.height * ratio : bitmap.width
  const sh = wide ? bitmap.height : bitmap.width / ratio
  const sx = (bitmap.width - sw) / 2
  const sy = (bitmap.height - sh) / 2
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const ctx = canvas.getContext('2d')
  if (!ctx) {
    bitmap.close()
    throw new Error('Canvas is not available')
  }
  ctx.fillStyle = '#000000'
  ctx.fillRect(0, 0, width, height)
  ctx.drawImage(bitmap, sx, sy, sw, sh, 0, 0, width, height)
  bitmap.close()
  const encode = (quality: number) =>
    new Promise<Blob>((resolve, reject) => {
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not encode the banner'))), 'image/jpeg', quality)
    })
  let blob = await encode(0.8)
  if (blob.size > BANNER_MAX_BYTES) blob = await encode(0.6)
  if (blob.size > BANNER_MAX_BYTES) throw new Error('That image is still too large after shrinking')
  return blob
}