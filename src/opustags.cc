#include <config.h>

#include "opustags.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ogg/ogg.h>

/**
 * Check if two filepaths point to the same file, after path canonicalization.
 * The path "-" is treated specially, meaning stdin for path_in and stdout for path_out.
 */
static bool same_file(const std::string& path_in, const std::string& path_out)
{
	if (path_in == "-" || path_out == "-")
		return false;
	char canon_in[PATH_MAX+1], canon_out[PATH_MAX+1];
	if (realpath(path_in.c_str(), canon_in) && realpath(path_out.c_str(), canon_out)) {
		return (strcmp(canon_in, canon_out) == 0);
	}
	return false;
}

/**
 * Parse the packet as an OpusTags comment header, apply the user's modifications, and write the new
 * packet to the writer.
 */
static ot::status process_tags(const ogg_packet& packet, const ot::options& opt, ot::ogg_writer& writer)
{
	ot::opus_tags tags;
	if(ot::parse_tags((char*) packet.packet, packet.bytes, &tags) != ot::status::ok)
		return ot::status::bad_comment_header;

	if (opt.delete_all) {
		tags.comments.clear();
	} else {
		for (const std::string& name : opt.to_delete)
			ot::delete_tags(&tags, name.c_str());
	}

	if (opt.set_all)
		tags.comments = ot::read_comments(stdin);
	for (const std::string& comment : opt.to_add)
		tags.comments.emplace_back(comment);

	if (writer.file) {
		auto packet = ot::render_tags(tags);
		if(ogg_stream_packetin(&writer.stream, &packet) == -1)
			return ot::status::libogg_error;
	} else {
		ot::print_comments(tags.comments, stdout);
	}

	return ot::status::ok;
}

static int run(ot::options& opt)
{
    if (!opt.path_out.empty() && same_file(opt.path_in, opt.path_out)) {
        fputs("error: the input and output files are the same\n", stderr);
        return EXIT_FAILURE;
    }
    ot::ogg_reader reader;
    ot::ogg_writer writer;
    if (opt.path_in == "-") {
        reader.file = stdin;
    } else {
        reader.file = fopen(opt.path_in.c_str(), "r");
        if (reader.file == nullptr) {
            perror("fopen");
            return EXIT_FAILURE;
        }
    }
    writer.file = NULL;
    if (opt.inplace != nullptr)
        opt.path_out = opt.path_in + opt.inplace;
    if (!opt.path_out.empty()) {
        if (opt.path_out == "-") {
            writer.file = stdout;
        } else {
            if (!opt.overwrite && !opt.inplace){
                if (access(opt.path_out.c_str(), F_OK) == 0) {
                    fprintf(stderr, "'%s' already exists (use -y to overwrite)\n", opt.path_out.c_str());
                    fclose(reader.file);
                    return EXIT_FAILURE;
                }
            }
            writer.file = fopen(opt.path_out.c_str(), "w");
            if(!writer.file){
                perror("fopen");
                fclose(reader.file);
                return EXIT_FAILURE;
            }
        }
    }
    const char *error = NULL;
    int packet_count = -1;
    while(error == NULL){
        // Read the next page.
        ot::status rc = reader.read_page();
        if (rc == ot::status::end_of_file) {
            break;
        } else if (rc != ot::status::ok) {
            if (rc == ot::status::standard_error)
                error = strerror(errno);
            else
                error = "error reading the next ogg page";
            break;
        }
        // Short-circuit when the relevant packets have been read.
        if(packet_count >= 2 && writer.file){
            if(ot::write_page(&reader.page, writer.file) == -1){
                error = "write_page: fwrite error";
                break;
            }
            continue;
        }
        // Initialize the streams from the first page.
        if(packet_count == -1){
            if(ogg_stream_init(&reader.stream, ogg_page_serialno(&reader.page)) == -1){
                error = "ogg_stream_init: couldn't create a decoder";
                break;
            }
            if(writer.file){
                if(ogg_stream_init(&writer.stream, ogg_page_serialno(&reader.page)) == -1){
                    error = "ogg_stream_init: couldn't create an encoder";
                    break;
                }
            }
            packet_count = 0;
        }
        if(ogg_stream_pagein(&reader.stream, &reader.page) == -1){
            error = "ogg_stream_pagein: invalid page";
            break;
        }
        // Read all the packets.
        while(ogg_stream_packetout(&reader.stream, &reader.packet) == 1){
            packet_count++;
            if (packet_count == 1) { // Identification header
                rc = ot::validate_identification_header(reader.packet);
                if (rc != ot::status::ok) {
                    error = ot::error_message(rc);
                    break;
                }
            } else if (packet_count == 2) { // Comment header
                rc = process_tags(reader.packet, opt, writer);
                if (rc != ot::status::ok) {
                    error = ot::error_message(rc);
                    break;
                }
                if (!writer.file)
                    break; /* nothing else to do */
                else
                    continue; /* process_tags wrote the new packet */
            }
            if(writer.file){
                if(ogg_stream_packetin(&writer.stream, &reader.packet) == -1){
                    error = "ogg_stream_packetin: internal error";
                    break;
                }
            }
        }
        if(error != NULL)
            break;
        if(ogg_stream_check(&reader.stream) != 0)
            error = "ogg_stream_check: internal error (decoder)";
        // Write the page.
        if(writer.file){
            ogg_page page;
            ogg_stream_flush(&writer.stream, &page);
            if(ot::write_page(&page, writer.file) == -1)
                error = "write_page: fwrite error";
            else if(ogg_stream_check(&writer.stream) != 0)
                error = "ogg_stream_check: internal error (encoder)";
        }
        else if(packet_count >= 2) // Read-only mode
            break;
    }
    fclose(reader.file);
    if(writer.file)
        fclose(writer.file);
    if(!error && packet_count < 2)
        error = "opustags: invalid file";
    if(error){
        fprintf(stderr, "%s\n", error);
        if (!opt.path_out.empty() && writer.file != stdout)
            remove(opt.path_out.c_str());
        return EXIT_FAILURE;
    }
    else if (opt.inplace) {
        if (rename(opt.path_out.c_str(), opt.path_in.c_str()) == -1) {
            perror("rename");
            return EXIT_FAILURE;
        }
    }
    return EXIT_SUCCESS;
}

int main(int argc, char** argv) {
	ot::status rc;
	ot::options opt;
	rc = process_options(argc, argv, opt);
	if (rc == ot::status::exit_now)
		return EXIT_SUCCESS;
	else if (rc != ot::status::ok)
		return EXIT_FAILURE;
	return run(opt);
}
