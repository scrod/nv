//
//  NSString_Textile.m
//  http://github.com/gjherbiet/nv/blob/0da680c487c0f7c277e35a9308ebf50535e7ee06/NSString-Textile.m
//

#import "NSString_Textile.h"

@implementation NSString (Textile)

+ (NSString*)stringWithProcessedTextile:(NSString*)inputString
{
	NSString* mdScriptPath = [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"Textile_2.12"] stringByAppendingPathComponent:@"textilize.pl"];
	
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