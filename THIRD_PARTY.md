# Third-party notices

Serge's own configuration layer is MIT licensed — see [LICENSE](LICENSE). Some of
the skills and slash commands in this repository are adapted from other people's
work. Those parts remain under their original licenses, listed here.

Each adapted file also carries an attribution line in its own text; this file is
the summary, not a replacement for those.

Nothing in this repository vendors the engine. See the SCOPE section of
[LICENSE](LICENSE) for why that matters.

---

## SuperClaude Framework — MIT

**Used by:** `dot-serge/commands/sc/` (7 commands: `analyze`, `brainstorm`,
`git`, `implement`, `research`, `test`, `troubleshoot`)

`analyze`, `git`, and `troubleshoot` are unmodified. `brainstorm`, `implement`,
`research`, and `test` are modified to fit Serge's router seats and hooks.

Source: <https://github.com/SuperClaude-Org/SuperClaude_Framework>

```
MIT License

Copyright (c) 2024 SuperClaude Framework Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## obra/superpowers — MIT

**Used by:** `dot-serge/skills/debugging/` (adapted)

Source: <https://github.com/obra/superpowers>

```
MIT License

Copyright (c) 2025 Jesse Vincent

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## snarktank/ralph — MIT

**Used by:** `dot-serge/skills/tabarnak/` (ported and renamed)

The story-by-story build loop. Renamed to `tabarnak` in this repository; the
loop structure and the deterministic per-story gate are from the original.

Source: <https://github.com/snarktank/ralph>

```
MIT License

Copyright (c) 2026 snarktank

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## anthropics/skills — Apache License 2.0

**Used by:**

| This repository | Upstream skill |
| --- | --- |
| `dot-serge/skills/frontend-design/` | `skills/frontend-design/` |
| `dot-serge/skills/theme-factory/` | `skills/theme-factory/` |
| `dot-serge/skills/skill-authoring/` | `skills/skill-creator/` |

All three are **modified** from the originals — rewritten to target Serge's
seats, hooks, and skill format, and trimmed of material that does not apply
here. Apache-2.0 §4(b) requires that modification be stated; this is that
statement.

Source: <https://github.com/anthropics/skills> — each upstream skill directory
carries its own `LICENSE.txt` (Apache License, Version 2.0).

> Licensed under the Apache License, Version 2.0 (the "License"); you may not
> use these files except in compliance with the License. You may obtain a copy
> of the License at
>
> <http://www.apache.org/licenses/LICENSE-2.0>
>
> Unless required by applicable law or agreed to in writing, software
> distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
> WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
> License for the specific language governing permissions and limitations under
> the License.

**Note on scope:** that upstream repository is mixed-license. Its README states
that many skills are open source under Apache 2.0, while its *document* skills
(docx, pptx, xlsx, pdf) are source-available rather than open source. Only the
three Apache-2.0 skills above were adapted. Serge's own document tooling under
`dot-serge/skills/office/` is written from scratch and is not derived from the
upstream document skills.
