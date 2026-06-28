namespace AcaQueueRepro.Worker.Models;

/// <summary>
/// The lifecycle states a job can be recorded in. The critical distinction for the
/// reproduction is between <see cref="Started"/>/<see cref="Progress"/> and
/// <see cref="Completed"/>: a job that has the former but never the latter, combined with a
/// shutdown/scale-in event, is the failure we are trying to prove.
/// </summary>
public enum JobState
{
    Queued,
    Started,
    Progress,
    Completed,
    Interrupted,
    Failed
}
