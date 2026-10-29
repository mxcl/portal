#!/usr/bin/env python3
"""Deterministic sample-project output for Portal's filmed command blocks."""
import re
import sys
import time

# Use the terminal's own 16-color theme, including its default foreground.
C = '\033[36m'; G = '\033[32m'; M = '\033[35m'
D = '\033[90m'; W = '\033[39m'; R = '\033[0m'


def line(text):
    print(text + R, flush=True)
    time.sleep(0.045)


scenes = {
    'explore': [
        f'{C}orbit{D} / a little space for big ideas',
        f'{D}PATH                          FILES    PURPOSE                              ENTRY POINT',
        f'{D}├── {W}src/app/                   {C}12     {W}Application shell and navigation     {D}app.tsx',
        f'{D}├── {W}src/components/            {C}24     {W}Shared controls and motion           {D}index.ts',
        f'{D}├── {W}public/                    {C}18     {W}Fonts, icons, and textures            {D}manifest.json',
        f'{D}└── {W}tests/                     {C}56     {W}Unit and integration coverage        {D}vitest.config.ts',
    ],
    'graph': [
        f'{D}HISTORY       BRANCH             CHANGE                                      AUTHOR       AGE',
        f'{C}● {W}a8f4c21     {G}main               {W}Refine the launch experience                {D}Alex         2 min',
        f'{C}│ {M}● {W}e92b718   {M}motion             {W}Add spring transitions and orbital motion   {D}Sam          8 min',
        f'{C}●─╯ {W}7d3a604   {G}main               {W}Bring components and routes together        {D}Alex        24 min',
    ],
    'check': [
        f'{D}CHECK              RESULT           SCOPE                                   DURATION',
        f'{G}✓ {W}TypeScript       {G}clean            {W}38 modules · strict mode                 {D}412 ms',
        f'{G}✓ {W}Styles           {G}consistent       {W}24 components · 6 shared tokens          {D}186 ms',
        f'{G}✓ {W}Assets           {G}ready            {W}18 files · compressed and fingerprinted  {D} 94 ms',
    ],
    'test': [
        f'{D}SUITE              PASSED    COVERAGE                                      TIME',
        f'{G}✓ {W}navigation       {G}12 / 12   {C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  {W}100%   {D}128 ms',
        f'{G}✓ {W}components       {G}28 / 28   {C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{D}──  {W} 94%   {D}204 ms',
        f'{G}✓ {W}interactions     {G}16 / 16   {C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{D}─  {W} 97%   {D}156 ms',
        f'{G}56 passed{D} · 0 failed · 3 suites                                      {W}488 ms total',
    ],
    'bench': [
        f'{D}METRIC       LAST 48 FRAMES                                      CURRENT      BUDGET',
        f'{W}render       {C}▁▂▃▂▄▅▃▂▁▂▃▂▁▁▂▃▂▄▅▄▂▁▂▃▂▁▂▃▄▃▂▁▁▂▃▂▄▃▂▁▂▃▂▁▁▂▃▂  {W} 4.2 ms      {G}< 16 ms',
        f'{W}memory       {M}▂▂▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃▃  {W}18.0 MB      {G}< 32 MB',
        f'{W}frame budget {G}━━━━━━━━━━━━{D}────────────────────────────────────  {W}26% used     {G}headroom to spare',
    ],
    'diff': [
        f'{D}src/scene.ts                                                     {G}+2 {D}/ −0 · motion',
        f'{G}+ const motion = spring({{ stiffness: 120, damping: 18, precision: 0.001 }});',
        f'{G}+ scene.animate({{ orbit: 1, light: "violet", duration: 800, easing: motion }});',
        f'{D}2 additions · 1 file changed                                     {G}ready for liftoff',
    ],
    'assets': [
        f'{D}ARTIFACT                 ORIGINAL     COMPRESSED    REDUCTION                         STATUS',
        f'{W}index.html                 5.8 kB         2.4 kB     {C}━━━━━━━━━━━━━━━━━{D}───────────  {W}59%   {G}ready',
        f'{W}app.js                   168.2 kB        42.8 kB     {C}━━━━━━━━━━━━━━━━━━━━━{D}───────  {W}75%   {G}ready',
        f'{W}style.css                 31.4 kB         8.1 kB     {C}━━━━━━━━━━━━━━━━━━━━━{D}───────  {W}74%   {G}ready',
    ],
    'status': [
        f'{G}✓ {W}Working tree clean                                           {G}all checks passed',
        f'{D}BRANCH          TRACKING               FILES       TESTS         BUILD',
        f'{C}main            {W}origin/main            {G}0 changed   56 passed     {W}53.3 kB · production',
    ],
    'preview': [
        f'{G}● {W}Orbit is ready.                                              {D}startup in {W}218 ms',
        f'{D}Local    {C}http://localhost:3000                               {G}● {W}server listening',
        f'{D}Build    {W}production · 53.3 kB                                {G}✓ {W}all routes ready',
        f'{D}Made for a little more possibility.',
    ],
}


def build_row(step):
    n = step * 3
    return f'{C}{"━" * n}{D}{"─" * (48 - n)}  {W}{int(step / 16 * 100):3}%  {D}compiling orbit · 38 modules'


def self_test():
    rows = [row for scene in scenes.values() for row in scene] + [build_row(i) for i in range(17)]
    for row in rows:
        assert all(code in {'0', '32', '35', '36', '39', '90'}
                   for code in re.findall(r'\033\[([^m]*)m', row))
        plain = re.sub(r'\033\[[0-9;]*m', '', row)
        assert '\033' not in plain and len(plain) <= 110, repr(plain)
    print('All demo rows use standard ANSI colors and fit within 110 columns.')


if __name__ == '__main__':
    name = sys.argv[1]
    if name == '--self-test':
        self_test()
    elif name == 'build':
        for step in range(17):
            print('\r' + build_row(step), end='', flush=True)
            time.sleep(.085)
        print(R)
        line(f'{G}✓ {W}Production build complete {D}· 38 modules · 3 artifacts              {W}53.3 kB total')
    else:
        assert name in scenes, f'Unknown scene: {name}'
        for row in scenes[name]:
            line(row)
