/** @type {import('next').NextConfig} */
// The panel only renders local /brand images, and /_next/image sits outside
// the auth middleware: no remote hosts, and images are served as-is so the
// optimizer never decodes them.
const nextConfig = { images: { unoptimized: true } };

export default nextConfig;
