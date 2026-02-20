from PIL import Image
import os
import subprocess

directory = '/Users/mohammadshayani/Desktop/Vibe/mobile/assets/Wallpapers/'

def process_file(filename):
    if not filename.endswith('.PNG'):
        return
    
    base_name = filename[:-4]
    output_filename = f"{base_name.lower()}_transparent.png"
    input_path = os.path.join(directory, filename)
    output_path = os.path.join(directory, output_filename)
    
    print(f"Processing {input_path} -> {output_path}...")
    
    try:
        img = Image.open(input_path).convert("RGBA")
        datas = img.getdata()
        
        new_data = []
        for item in datas:
            r, g, b, a = item
            luminance = int((r + g + b) / 3)
            new_alpha = 255 - luminance
            if new_alpha < 5: 
                new_alpha = 0
            new_data.append((0, 0, 0, new_alpha))
            
        img.putdata(new_data)
        img.save(output_path, "PNG")
        
        # Optimize
        temp_optimized = os.path.join(directory, f"{base_name.lower()}_optimized.png")
        subprocess.run(['sips', '-s', 'format', 'png', output_path, '--out', temp_optimized], capture_output=True)
        os.replace(temp_optimized, output_path)
        
        print(f"Success: {output_filename}")
    except Exception as e:
        print(f"Error processing {filename}: {e}")

# Process all .PNG files
for file in os.listdir(directory):
    if file.endswith('.PNG'):
        process_file(file)
