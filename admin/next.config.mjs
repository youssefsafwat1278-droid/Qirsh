/** @type {import('next').NextConfig} */
// No remote image hosts: the panel only renders local /brand images through
// next/image, and /_next/image sits outside the auth middleware.
const nextConfig = {};

export default nextConfig;
