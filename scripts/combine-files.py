#!/usr/bin/env python3
import os

# Configuration
SOURCE_DIR = "."
OUTPUT_FILE = "combined.txt"

# Files to include based on extension
EXTENSIONS = {".sh", ".py", ".tf", ".yaml", ".yml", ".json", ".md"}

# Specific filenames to include (regardless of extension)
INCLUDE_FILES = {"Makefile", "README.md", "README.MD", ".gitignore"}

# Directories to ignore
IGNORE_DIRS = {".git", ".idea", "__pycache__", "venv", "node_modules", ".terraform"}

def combine_files(source_dir, output_file):
    try:
        with open(output_file, "w", encoding="utf-8") as outfile:
            for root, dirs, files in os.walk(source_dir):
                # Modify dirs in-place to skip ignored directories
                dirs[:] = [d for d in dirs if d not in IGNORE_DIRS]

                for filename in files:
                    ext = os.path.splitext(filename)[1]
                    
                    # Check if file matches extension OR is in the specific include list
                    if ext in EXTENSIONS or filename in INCLUDE_FILES:
                        # Skip the output file itself to avoid infinite loops/bloat
                        if filename == OUTPUT_FILE:
                            continue

                        file_path = os.path.join(root, filename)
                        
                        # Create a header
                        header = f"\n{'='*50}\nFILE: {file_path}\n{'='*50}\n"
                        
                        try:
                            with open(file_path, "r", encoding="utf-8") as infile:
                                content = infile.read()
                                outfile.write(header)
                                outfile.write(content)
                                outfile.write("\n") # Ensure separation
                                print(f"Added: {file_path}")
                        except Exception as e:
                            print(f"Skipping {file_path} due to error: {e}")
                            
        print(f"\nSuccess! All files combined into '{output_file}'")

    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    combine_files(SOURCE_DIR, OUTPUT_FILE)