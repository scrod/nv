#import "NSString-Markdown.h"

@implementation NSString (Markdown)

+ (NSString*)stringWithProcessedMarkdown:(NSString*)inputString
{
	NSString* mdScriptPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"MultiMarkdown.pl"];
	NSString* spScriptPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"SmartyPants.pl"];
	
	NSTask* task = [[NSTask alloc] init];
	NSMutableArray* args = [NSMutableArray array];
	NSTask* task2 = [[NSTask alloc] init];
	NSMutableArray* args2 = [NSMutableArray array];
		
    [args addObject:mdScriptPath];
    [task setArguments:args];
	[args2 addObject:spScriptPath];
    [task2 setArguments:args2];
	
	NSPipe* stdinPipe = [NSPipe pipe];
	NSPipe* stdoutPipe = [NSPipe pipe];
	NSFileHandle* stdinFileHandle = [stdinPipe fileHandleForWriting];
	NSFileHandle* stdoutFileHandle = [stdoutPipe fileHandleForReading];
	NSPipe* stdinPipe2 = [NSPipe pipe];
	NSPipe* stdoutPipe2 = [NSPipe pipe];
	NSFileHandle* stdinFileHandle2 = [stdinPipe2 fileHandleForWriting];
	NSFileHandle* stdoutFileHandle2 = [stdoutPipe2 fileHandleForReading];
	
	[task setStandardInput:stdinPipe];
	[task setStandardOutput:stdoutPipe];
	[task2 setStandardInput:stdinPipe2];
	[task2 setStandardOutput:stdoutPipe2];
	
    [task setLaunchPath:@"/usr/bin/perl"];	
    [task launch];
    [task2 setLaunchPath:@"/usr/bin/perl"];	
    [task2 launch];
	
	[stdinFileHandle writeData:[inputString dataUsingEncoding:NSUTF8StringEncoding]];
	[stdinFileHandle closeFile];
	
	NSData* outputData = [stdoutFileHandle readDataToEndOfFile];
	NSString* outputString = [[[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] autorelease];
	[stdoutFileHandle closeFile];

	[stdinFileHandle2 writeData:[outputString dataUsingEncoding:NSUTF8StringEncoding]];
	[stdinFileHandle2 closeFile];

	NSData* spOutputData = [stdoutFileHandle2 readDataToEndOfFile];
	NSString* spOutputString = [[[NSString alloc] initWithData:spOutputData encoding:NSUTF8StringEncoding] autorelease];
	[stdoutFileHandle2 closeFile];
	
	[task waitUntilExit];
	[task2 waitUntilExit];
	
	
	return spOutputString;
}

@end