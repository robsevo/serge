# What this changes

<!-- One or two sentences. Which file, and what behaviour changes. -->

## What failure it prevents

<!--
The convention here: every guard names the specific thing that went wrong.
Not "improves robustness" — the actual symptom, ideally with how you hit it.
If this is a docs or tidy-up change, write "n/a — cleanup".
-->

## How it was verified

<!--
An actual command and its output. Hooks read JSON on stdin, so drive it:

    printf '{"session_id":"t","last_assistant_message":"done","cwd":"/tmp"}' \
      | bash dot-serge/stop-checks.sh; echo "exit=$?"

"Tested locally" is not verification.
-->

```
paste the command and its output here
```

## Checklist

- [ ] `bash -n` parses every script I touched
- [ ] It exits 0 on an empty or malformed payload (fails open)
- [ ] It exits 0 when its dependencies are missing
- [ ] New hooks open with a `WHY` block naming the failure they prevent
- [ ] No API keys, personal paths, machine names or session IDs anywhere in the diff
- [ ] If I changed a model seat, `litellm.yaml`'s comment says what I measured
- [ ] If I added a skill, its directory name matches its `name:` frontmatter

## Cost

<!--
Does this add a model call, or latency to every turn? Serge targets $0/month on
free tiers, so a per-turn cost needs justifying. "None" is a fine answer.
-->
