const fs = require('fs');
const file = 'app/(tabs)/home.tsx';
let data = fs.readFileSync(file, 'utf8');

data = data.replace(
  /) : useNativeHeaderGlassButtons \? \([\s\S]*?\) : \(/g, 
  ') : false ? (null) : ('
);

fs.writeFileSync(file, data);
