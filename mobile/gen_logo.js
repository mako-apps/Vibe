const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const svgCode = fs.readFileSync(path.join(__dirname, 'assets/logos/logo.svg'), 'utf8')
    .replace(/fill="#111111"/g, 'fill="#FFFFFF"');

sharp(Buffer.from(svgCode))
    .resize(1024, 1024, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .extend({
        top: 100,
        bottom: 100,
        left: 100,
        right: 100,
        background: { r: 0, g: 0, b: 0, alpha: 0 }
    })
    .png()
    .toFile(path.join(__dirname, 'assets/logos/logo1.png'))
    .then(() => console.log('Successfully generated logo1.png'))
    .catch(err => {
        console.error(err);
        process.exit(1);
    });
