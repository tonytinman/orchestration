CREATE proc [run].[StartProcess] @QueueID int
as
begin
      update run.processqueue set
            ProcessStartDate=getdate()
            ,ProcessStatus='IN PROGRESS'
      where QueueID=@QueueID
end
GO
