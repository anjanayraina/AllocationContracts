import os
import re

src_dir = "c:\\Users\\Anjanay\\Desktop\\AllocationContracts\\src"

for filename in os.listdir(src_dir):
    if filename.endswith(".sol"):
        filepath = os.path.join(src_dir, filename)
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
        
        new_lines = []
        for line in lines:
            stripped = line.strip()
            # If line is a NatSpec comment starting with ///, keep it
            if stripped.startswith("///"):
                new_lines.append(line)
            # If line starts with double slash //, remove it (ignore it)
            elif stripped.startswith("//"):
                # Also keep the pragma and SPDX comments if they have double slashes
                if "SPDX-License-Identifier" in line:
                    new_lines.append(line)
                else:
                    # Skip decorative banners and general comments starting with //
                    continue
            else:
                # If there's an inline comment like "uint256 x; // comment", let's clean it up or keep it
                # To be 100% safe, we can keep inline comments or strip them. Let's strip only comments that take up a full line
                new_lines.append(line)
                
        with open(filepath, "w", encoding="utf-8") as f:
            f.writelines(new_lines)

print("Comments cleaned successfully!")
