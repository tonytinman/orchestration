CREATE procedure [run].[LogTelemetry] @LoadID varchar(100),@Message varchar(400)
as
insert run.Telemetry ([LoadID],[Message])
values(@LoadID,@Message)
GO
