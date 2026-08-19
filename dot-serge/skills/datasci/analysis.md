# Wrangling & statistics — pandas/scipy with care

## Wrangling idioms (pandas)

- Get to **tidy**: one row = one observation, one column = one variable.
  Wide→long `melt`, long→wide `pivot_table`. Most "hard" analyses are just
  untidy data.
- Chain with `.assign()`/`.query()`/`.pipe()` for a readable pipeline;
  each step should be printable — debug by looking at intermediate frames,
  not by rerunning blind.
- **Joins are where data dies**: check row counts before/after every merge
  (`validate="one_to_one"` / `"many_to_one"` kwarg makes pandas enforce it);
  an unexpected row explosion = duplicate keys; silent shrinkage = key
  mismatch (dtypes! `"42" != 42`, categorical traps, whitespace).
- Dates: parse explicitly (`pd.to_datetime(..., format=...)`), keep tz-aware
  if any source is; resample (`df.resample("W").sum()`) for time series.
- Missing data: distinguish "missing = zero" from "missing = unknown" BEFORE
  filling; `fillna(0)` on unknowns manufactures data. Report the null rate
  per column you actually use.
- Outliers: look before dropping (plot it) — an "outlier" is often the
  finding. If trimming, state rule and count.

## Statistics that hold up

- **Describe first**: n, mean/median (both — divergence = skew), std, range,
  group sizes. Small n gets said out loud, not hidden in an aggregate.
- **Comparisons**: scipy.stats — t-test (Welch's by default), Mann-Whitney
  when distributions are ugly, chi-square for counts. ALWAYS pair the p-value
  with an effect size (Cohen's d, difference in medians, risk ratio) — "significant"
  and "matters" are different claims.
- **Many comparisons**: testing 20 things finds 1 fake winner at p<.05 by
  construction — Bonferroni/BH-correct or call it exploratory.
- **Correlation**: `.corr()` (Pearson) vs rank (Spearman) chosen by shape;
  name the obvious confounder before reporting r; correlation across time
  series is inflated by shared trend — difference or detrend first.
- **Trends**: a fitted line on 6 points is decoration, not inference; for
  real time-series claims use enough history and validate out-of-sample.
- Uncertainty: bootstrap CIs (numpy resampling, 20 lines) beat hand-waving
  when the user needs "how sure are we".

## Reporting

Every number ships with: denominator, time window, source, and the one-line
caveat that most threatens it. The script that produced it is part of the
deliverable. When results contradict the user's expectation, show the
pipeline check that convinced you the number is real.
