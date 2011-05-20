//
// NSString-Markdown.m
// http://github.com/panicsteve/nv/commit/ce6bf6e5cc3a635ed51fbecffd486ee97808220e
//

#import "NSString_Markdown.h"
#import "NoteObject.h"

@implementation NSString (Markdown)

+ (NSString*)stringWithProcessedMarkdown:(NSString*)inputString
{
	NSString* mdScriptPath = [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"Markdown_1.0.1"] stringByAppendingPathComponent:@"Markdown.pl"];
	
	NSTask* task = [[NSTask alloc] init];
    NSMutableArray* args = [NSMutableArray array];
 
    [args addObject:mdScriptPath];
    [task setArguments:args];
	
	NSPipe* stdinPipe = [NSPipe pipe];
	NSPipe* stdoutPipe = [NSPipe pipe];
	NSFileHandle* stdinFileHandle = [stdinPipe fileHandleForWriting];
	NSFileHandle* stdoutFileHandle = [stdoutPipe fileHandleForReading];
		
	[task setStandardInput:stdinPipe];
	[task setStandardOutput:stdoutPipe];
	
    [task setLaunchPath:@"/usr/bin/perl"];	
    [task launch];
	
	[stdinFileHandle writeData:[inputString dataUsingEncoding:NSUTF8StringEncoding]];
	[stdinFileHandle closeFile];
	
	NSData* outputData = [stdoutFileHandle readDataToEndOfFile];
	NSString* outputString = [[[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] autorelease];
	[stdoutFileHandle closeFile];

	[task waitUntilExit];

	return outputString;
}

@end
