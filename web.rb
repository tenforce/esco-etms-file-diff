require 'fileutils'

## constants
LINES_PER_INSERT = 50
LINES_PER_EXTRACT = 10000
GRAPH_BASE = "http://tmp.graph.com/"
GRAPH_A = GRAPH_BASE + "A"
GRAPH_B = GRAPH_BASE + "B"
DIFF_GRAPH_BASE = "http://tmp.graph.com/differences/"
DIFF_GRAPH_A = DIFF_GRAPH_BASE + "A"
DIFF_GRAPH_B = DIFF_GRAPH_BASE + "B"

PUBLICATIONs_PATH = ENV["PUBLISHER_EXPORT_PATH"]
DIFFERENCE_FILES_PATH = ENV["DIFFERENCE_FILE_EXPORT_PATH"]

## incoming route
## takes 2 publications ID's, fetches the files for
## those publicationas, caluclates the difference files and returns them
get '/publication-delta' do
  if !params[:pub1] || !params[:pub2]
    error("The source file should be passed in the parameter [file1] and the compared file should be passed in the parameter [file2]", 400)
  end
  publication1 = params[:pub1]
  publication2 = params[:pub2]

  file1 = get_filename_for_publication(publication1)
  file2 = get_filename_for_publication(publication2)

  log.info "file 1: #{file1}"
  log.info "file 2: #{file2}"

  diff_filename = get_file_delta(file1, file2)

  log.info "difference file: #{diff_filename}"
  send_file diff_filename
end

## incoming route
## takes 2 file params for now, those should change to id params
## returns a file with the differences between 2 publications
get '/file-delta' do
  if !params[:file1] || !params[:file2]
    error("The source file should be passed in the parameter [file1] and the compared file should be passed in the parameter [file2]", 400)
  end
  file1 = params[:file1]
  file2 = params[:file2]

  diff_filename = get_file_delta(file1, file2)

  send_file diff_filename
end

## creates the difference file IF it does not exist otherwise
## it just returns the file that already exists (kind of cached)
def get_file_delta(file1, file2)
  diff_filename = calculate_diff_filename(file1, file2)

  # if the file already exists we can just return it immediatly
  if File.exist? diff_filename
    log.info 'File already calculated'
    return diff_filename
  end

  # load the files in to graphs
  clear_graph GRAPH_A
  clear_graph GRAPH_B
  read_file_into_graph(file1, GRAPH_A)
  read_file_into_graph(file2, GRAPH_B)

  # loading the differences
  clear_graph DIFF_GRAPH_A
  clear_graph DIFF_GRAPH_B
  calculate_graph_diffs(GRAPH_A, GRAPH_B, DIFF_GRAPH_A)
  calculate_graph_diffs(GRAPH_B, GRAPH_A, DIFF_GRAPH_B)

  create_difference_file(DIFF_GRAPH_A, DIFF_GRAPH_B, diff_filename)

  log.info "[*] written to file: #{diff_filename}"
  return diff_filename
end

## small helper method that appends a line to a file
def append_line_to_file(filename, line)
  FileUtils.touch(filename)
  File.open(filename, 'a') do |f|
    f.puts line
  end
end

## queries the db for S P O statements and adds each on a separate
## line to the file prefixed with the prefix
def triple_output_to_file(graph_name, filename, prefix)
  base_query_addition = "SELECT ?s ?p ?o FROM <#{graph_name}> WHERE { ?s ?p ?o }"
  current_iteration = 0
  additions = query(base_query_addition + " OFFSET #{(LINES_PER_EXTRACT * current_iteration).to_s} LIMIT #{LINES_PER_EXTRACT}")
  while additions.length > 0
    additions.each_solution do |addition|
      log.info "#{prefix} #{addition['s'].to_s} #{addition['p'].to_s} #{addition['o'].to_s}"
      append_line_to_file(filename,"#{prefix} #{addition['s'].to_s} #{addition['p'].to_s} #{addition['o'].to_s}" + "\n")
    end
    log.info additions.to_s
    current_iteration += 1
    additions = query(base_query_addition + " OFFSET #{(LINES_PER_EXTRACT * current_iteration).to_s} LIMIT #{LINES_PER_EXTRACT}")
  end
end

## uses queries to effectively calculate the differences
## between 2 graphs and stores it into a file with the delta extension
def create_difference_file(diffgraph1, diffgraph2, filename)
  log.info "[*] Adding additions to difference file"
  FileUtils.touch(filename)
  triple_output_to_file(diffgraph1, filename, "+")
  log.info "[*] Adding removals to difference file"
  triple_output_to_file(diffgraph2, filename, "-")
  log.info "[*] Difference file created"
end

## calculates the filename that a file containing the difference between 2 files, file1 and fil2
## should have
def calculate_diff_filename(file1, file2)
  file1Name = file1.rpartition('/').last.rpartition('.').first
  file2Name = file2.rpartition('/').last.rpartition('.').first

  return "#{ENV["DIFFERENCE_FILE_EXPORT_PATH"]}/#{file1Name}-#{file2Name}.delta"
end

## returns the filename that is in the triple store associated with a publication's UUID
def get_filename_for_publication(publicationId)
  publicationFileQuery =
    "PREFIX dcterms: <http://purl.org/dc/terms/> " +
    "PREFIX mu: <http://mu.semte.ch/vocabularies/core/> " +
    "SELECT * " + 
    "FROM <http://mu.semte.ch/application> " +
    "WHERE " +
    "{ " +
    "?publication mu:uuid \"#{publicationId}\". " +
    "?publication <http://dbpedia.org/ontology/filename> ?filename . " +
    "} "

  result = query(publicationFileQuery)

  log.info result.to_s

  result.first["filename"].to_s

  # log.info result.first.to_h.to_s

  # log.info result.first.to_h["filename"].to_s
end

## puts the difference between GRAPH <graphname1> and GRAPH <graphname2>
## in a 3rd GRAPH <diffgraphname>
def calculate_graph_diffs(graphname1, graphname2, diffgraphname)
  update("INSERT { GRAPH <#{diffgraphname}> { ?s ?p ?o . }} WHERE { GRAPH <#{graphname1}> { ?s ?p ?o } FILTER NOT EXISTS { GRAPH <#{graphname2}> { ?s ?p ?o }}}")
end

## clears the graph with the given name
def clear_graph(graphname)
  update("WITH <#{graphname}> DELETE { ?s ?p ?o } WHERE { ?s ?p ?o .}")
end


## read_file_into_graph
## expect a filename of a turtle n3 file and a graphname
def read_file_into_graph(filename, graphname)
  line_counter = 0

  query_start = "INSERT DATA { GRAPH <#{graphname}> { "
  query_end = "} }"
  insert_block = ""

  File.open(filename).each do |line|
    insert_block += line + " "
    line_counter += 1
    
    if(line_counter > LINES_PER_INSERT)
      update("#{query_start}#{insert_block}#{query_end}")
      insert_block = ""
      line_counter = 0
    end
      
  end

  if insert_block.length > 0
    update("#{query_start}#{insert_block}#{query_end}")
  end

end  

## writes a test file
get '/up' do
  test_file = "#{DIFFERENCE_FILES_PATH}/testfile.txt"
  log.info "[?] File Diff Service writing testfile to #{test_file}"
  log.info "[?]LINES_PER_INSERT = #{LINES_PER_INSERT}"
  log.info "[?] LINES_PER_EXTRACT = #{LINES_PER_EXTRACT}"
  log.info "[?] GRAPH_BASE = #{GRAPH_BASE}"
  log.info "[?] GRAPH_A = #{GRAPH_A}"
  log.info "[?] GRAPH_B = #{GRAPH_B}"
  log.info "[?] DIFF_GRAPH_BASE = #{DIFF_GRAPH_BASE}"
  log.info "[?] DIFF_GRAPH_A = #{DIFF_GRAPH_A}"
  log.info "[?] DIFF_GRAPH_B = #{DIFF_GRAPH_B}"
  log.info "[?] PUBLICATIONs_PATH = #{PUBLICATIONs_PATH}"
  log.info "[?] DIFFERENCE_FILES_PATH = #{DIFFERENCE_FILES_PATH}"
  
  append_line_to_file(test_file, "testing....")
end

## test route to verify that the service is up
get '/ping' do
  log.info "[*] File Diff Service: Ping Pong"
  "pong"
end
