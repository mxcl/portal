#!/usr/bin/env python3
"""Deterministic sample-project output for Portal's filmed command blocks."""
import sys
import time

C='\033[38;2;100;205;255m'; G='\033[38;2;135;225;180m'
D='\033[38;2;145;150;175m'; W='\033[38;2;235;237;245m'; R='\033[0m'
def line(text):
    print(text + R, flush=True)
    time.sleep(0.045)
scenes = {
'explore': [f'{C}orbit{D} / a little space for big ideas', f'{D}├── {W}src/       {D}app · components · routes', f'{D}├── {W}public/    {D}fonts · icons · textures', f'{D}└── {W}tests/     {D}unit · integration'],
'graph': [f'{C}● {W}a8f4c21  {G}main {D}→ refine the launch experience', f'{C}│ {G}● {W}e92b718  {D}add orbital motion', f'{C}●─╯ {W}7d3a604  {D}bring everything together'],
'check': [f'{G}✓ {W}TypeScript   {D}strict · clean', f'{G}✓ {W}Styles       {D}24 components · consistent', f'{G}✓ {W}Assets       {D}optimized · ready'],
'test': [f'{G}✓ {W}navigation     {D}12 passed', f'{G}✓ {W}components     {D}28 passed', f'{G}✓ {W}interactions   {D}16 passed', f'{G}56 passed{D}  ·  0 failed'],
'bench': [f'{D}render   {C}▁▂▃▂▄▅▃▂▁▂▃▂▁▁  {W}4.2 ms', f'{D}memory   {C}▂▂▃▃▃▃▃▃▃▃▃▃▃▃  {W}18 MB', f'{D}budget   {G}━━━━━━━━━━━━━━  {W}well within reach'],
'diff': [f'{D}src/scene.ts', f'{G}+ const motion = spring({{ stiffness: 120 }});', f'{G}+ scene.animate({{ orbit: 1, light: "violet" }});', f'{D}2 additions · ready for liftoff'],
'assets': [f'{D}ARTIFACT             SIZE       STATUS', f'{W}index.html          2.4 kB      {G}ready', f'{W}app.js             42.8 kB      {G}ready', f'{W}style.css           8.1 kB      {G}ready'],
'status': [f'{G}✓ {W}Working tree clean', f'{D}main {C}● {D}all changes accounted for'],
'preview': [f'{G}● {W}Orbit is ready.', f'{D}Local   {C}http://localhost:3000', f'{D}Made for a little more possibility.'],
}
if __name__ == '__main__':
    name = sys.argv[1]
    if name == 'build':
        for step in range(17):
            n = min(20, int(step / 16 * 20))
            print(f'\r{C}{"━"*n}{D}{"─"*(20-n)}  {W}{int(step/16*100):3}%  {D}compiling orbit', end='', flush=True)
            time.sleep(.085)
        print(R)
        line(f'{G}✓ {W}Production build complete {D}· 53.3 kB')
    else:
        assert name in scenes, f'Unknown scene: {name}'
        for row in scenes[name]: line(row)
