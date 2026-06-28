# Observations log

Use this file to record what each reproduction attempt did. The goal is a clear, reproducible
record of which settings do and do not trigger premature termination. Do **not** assume the
first configuration reproduces the issue — iterate and log each run.

## How to log a run

Copy the template below for each attempt.

```
### Run <n> — <date/time UTC>

- Profile / settings: minReplicas=__ maxReplicas=__ queueLength=__ strategy=__
- Image: lightweight | ~3 GB (IMAGE_PADDING_GB=__)
- Batch enqueued: __ (e.g. 10x900,10x1500)
- Max replicas observed: __
- Visible vs. invisible queue depth behavior: __
- Jobs started: __ / completed: __ / interrupted: __ / failed: __
- Started-but-incomplete jobs: __ (job ids)
- Max AttemptNumber / dequeueCount seen: __
- Shutdown / scale-in events correlated in time? yes/no — evidence: __
- Outcome: REPRODUCED | NOT REPRODUCED
- Notes / next experiment: __
```

## Things to vary when iterating

- **Job duration** — longer jobs widen the window where a replica can be scaled in mid-work.
- **Burst size** — enqueue many messages at once so the app scales out, then no new messages
  arrive, so visible depth collapses while work continues.
- **`queueLengthStrategy`** — `visibleonly` makes in-flight (invisible) messages "disappear"
  from the scaler's view, encouraging scale-in; `all` keeps them counted.
- **`maxReplicas`** — higher fan-out means more replicas eligible for scale-in.
- **`minReplicas`** — `0` allows scaling all the way down (and the to-zero cooldown applies only
  to the last replica → other replicas can be removed sooner).
- **Visibility timeout** (`Worker__VisibilityTimeoutSeconds`) — must exceed max job duration,
  otherwise messages reappear mid-job for reasons unrelated to scale-in (a confound to avoid).

## Runs

<!-- Add runs below using the template above. -->
