import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
// import basicSsl from '@vitejs/plugin-basic-ssl'

// Get base path from command line (--base=/Vibe/) or default to '/'
// Get base path from command line (--base=/Vibe/) or default to '/'
// https://vitejs.dev/config/
export default defineConfig(() => {
  // Get base path from command line or environment
  // Default to '/' unless override provided (GitHub Pages script provides --base=/Vibe/)
  const base = process.env.VITE_BASE_PATH || '/';

  return {
    base,
    plugins: [
      // basicSsl(),
      react(),
      VitePWA({
        registerType: 'autoUpdate',
        strategies: 'injectManifest',
        srcDir: 'src',
        filename: 'sw.js',
        includeAssets: ['favicon.ico', 'apple-touch-icon.png', 'masked-icon.svg', 'logo.png'],
        manifest: {
          name: 'Vibe',
          short_name: 'Vibe',
          description: 'Secure End-to-End Encrypted Messenger',
          theme_color: '#191919',
          background_color: '#191919',
          display: 'standalone',
          orientation: 'portrait',
          start_url: base,
          scope: base,
          icons: [
            {
              src: 'logo.png',
              sizes: '192x192',
              type: 'image/png'
            },
            {
              src: 'logo.png',
              sizes: '512x512',
              type: 'image/png'
            }
          ]
        },
        manifestFilename: 'manifest.json', // Force .json extension
      })
    ],
    server: {
      proxy: {
        '/api': {
          target: 'http://localhost:4000',
          changeOrigin: true
        },
        '/socket': {
          target: 'http://localhost:4000',
          ws: true
        }
      }
    }
  }
})
