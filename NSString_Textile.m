//
//  NSString_Textile.m
//  http://github.com/gjherbiet/nv/blob/0da680c487c0f7c277e35a9308ebf50535e7ee06/NSString-Textile.m
//

#import "NSString_Textile.h"
#import "PreviewController.h"
#import "AppController.h"
#import "NoteObject.h"

@implementation NSString (Textile)

+(NSString*)processTextile:(NSString*)inputString
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

+(NSString*)documentWithProcessedTextile:(NSString*)inputString
{
    AppController *app = [[NSApplication sharedApplication] delegate];
    NSString *processedString = [self processTextile:inputString];
	NSString *htmlString = [[PreviewController class] html];
	NSString *cssString = [[PreviewController class] css];
	NSMutableString *outputString = [NSMutableString stringWithString:(NSString *)htmlString];
	NSString *noteTitle =  ([app selectedNoteObject]) ? [NSString stringWithFormat:@"%@",titleOfNote([app selectedNoteObject])] : @"";
	
	NSString *nvSupportPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Notational Velocity"];
	[outputString replaceOccurrencesOfString:@"{%support%}" withString:nvSupportPath options:0 range:NSMakeRange(0, [outputString length])];
	[outputString replaceOccurrencesOfString:@"{%title%}" withString:noteTitle options:0 range:NSMakeRange(0, [outputString length])];
	[outputString replaceOccurrencesOfString:@"{%content%}" withString:processedString options:0 range:NSMakeRange(0, [outputString length])];
	[outputString replaceOccurrencesOfString:@"{%style%}" withString:cssString options:0 range:NSMakeRange(0, [outputString length])];
	
	return outputString;
}

+(NSString*)xhtmlWithProcessedTextile:(NSString*)inputString
{
	AppController *app = [[NSApplication sharedApplication] delegate];
	NSString *noteTitle =  ([app selectedNoteObject]) ? [NSString stringWithFormat:@"%@",titleOfNote([app selectedNoteObject])] : @"";
	NSString *processedString = [self processTextile:inputString];
	return [NSString stringWithFormat:@"<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\"\n	\"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">\n\n<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\" lang=\"en\">\n<head>\n	<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"/>\n\n	<title>%@</title>\n	\n</head>\n\n<body>\n%@\n\n</body>\n</html>\n",noteTitle,processedString];
}

+(NSString*)stringWithProcessedTextile:(NSString*)inputString
{
	return [self processTextile:inputString];
}

@end
