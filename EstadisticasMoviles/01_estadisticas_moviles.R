# -----------------------------------------------------------------------------#
# --- PASO 1. Cargar paquetes necesarios ----
rm(list = ls()); gc()
Sys.setenv(TZ = "UTC")
list.of.packages <- c("dplyr", "jsonlite", "lubridate", "magrittr", 
                      "purrr", "stringr", "utils", "yaml", "R6", 
                      "futile.logger", "doSNOW", "foreach", "snow",
                      "iterators", "RPostgres", "data.table")
for (pack in list.of.packages) {
  if (!require(pack, character.only = TRUE)) {
    stop(paste0("Paquete no encontrado: ", pack))
  }
}
rm(pack); gc()
# ------------------------------------------------------------------------------

# -----------------------------------------------------------------------------#
# --- PASO 2. Leer archivo de configuracion ----
# -----------------------------------------------------------------------------#

normalize_dirnames <- function(dirnames) {
  if (is.atomic(dirnames)) 
    dirnames <- base::sub('/$', '', dirnames)
  if (!is.atomic(dirnames))
    for (nm in names(dirnames)) 
      dirnames[[nm]] <- normalize_dirnames(dirnames[[nm]])
  return (dirnames)
}

# a) YAML de configuracion del generador de estadísticas móviles
args <- base::commandArgs(trailingOnly = TRUE)
if (length(args) > 0) {
  archivo.config <- args[1]
} else {
  # No vino el archivo de configuracion por linea de comandos. Utilizo un archivo default
  archivo.config <- paste0(getwd(), "/configuracion_estadisticas_moviles.yml")
}
if (! file.exists(archivo.config)) {
  stop(paste0("El archivo de configuración ", archivo.config, " no existe\n"))
} else {
  cat(paste0("Leyendo archivo de configuración ", archivo.config, "...\n"))
  config <- yaml::yaml.load_file(archivo.config)
  config$dir <- normalize_dirnames(config$dir)
}

# b) YAML de parametros del generador de estadísticas móviles
if (length(args) > 1) {
  archivo.params <- args[2]
} else {
  # No vino el archivo de configuracion por linea de comandos. Utilizo un archivo default
  archivo.params <- paste0(getwd(), "/parametros_estadisticas_moviles.yml")
}
if (! file.exists(archivo.params)) {
  stop(paste0("El archivo de parámetros ", archivo.params, " no existe\n"))
} else {
  cat(paste0("Leyendo archivo de parámetros ", archivo.params, "...\n"))
  config$params <- yaml::yaml.load_file(archivo.params)
}

replace_run_identifier <- function(filenames, identifier) {
  if (is.atomic(filenames) && grepl("<\\*idc>", filenames))
    filenames <- base::sub('<\\*idc>', identifier, filenames)
  if (!is.atomic(filenames))
    for (nm in names(filenames)) 
      filenames[[nm]] <- replace_run_identifier(filenames[[nm]], identifier)
  return (filenames)
}

# c) YAML de configuración del intercambio de archivos del proceso de generación de índices
if (length(args) > 1) {
  archivo.nombres <- args[3]
} else {
  # No vino el archivo de configuracion por linea de comandos. Utilizo un archivo default
  archivo.nombres <- paste0(config$dir$data, "/configuracion_archivos_utilizados.yml")
}
if (! file.exists(archivo.nombres)) {
  stop(paste0("El archivo de configuración ", archivo.nombres, " no existe\n"))
} else {
  cat(paste0("Leyendo archivo de configuración ", archivo.nombres, "...\n"))
  config$files <- yaml::yaml.load_file(archivo.nombres)
  config$files <- replace_run_identifier(config$files, config$files$identificador_corrida)
}

rm(archivo.config, archivo.params, archivo.nombres, args); gc()
# ------------------------------------------------------------------------------

# -----------------------------------------------------------------------------#
# --- PASO 3. Cargar librerias propias e iniciar script ----
# -----------------------------------------------------------------------------#

# a) Cargar librerias
source(glue::glue("{config$dir$lib}/FechaUtils.R"), echo = FALSE)
source(glue::glue("{config$dir$lib}/Script.R"), echo = FALSE)
source(glue::glue("{config$dir$lib}/Task.R"), echo = FALSE)
source(glue::glue("{config$dir$lib}/Helpers.R"), echo = FALSE)


# b.1) Definir nombre del script
script_name <- "EstadisticaMovil"
script_logfile <- glue::glue("{config$dir$run}/{script_name}.log")

# b.2) borrar archivo .log de corridas anteriores
if (file.exists(script_logfile))
  file.remove(script_logfile)

# b.3) Iniciar script
# Si el directorio run para almacenar los log no existe, crearlo
if (!fs::dir_exists(config$dir$run)) {
  fs::dir_create(config$dir$run)
}
script <- Script$new(run.dir = config$dir$run, name = script_name, create.appender = T)
script$start()

# Crear directorios para guardar resultados intermedios
if (!fs::dir_exists(glue::glue("{config$dir$data}/partial"))) {
  fs::dir_create(glue::glue("{config$dir$data}/partial"))
}

# c) Obtener datos producidos por el generador y filtrarlos
script$info("Leyendo csv con datos de entrada")
csv_filename <- glue::glue("{config$dir$data}/{config$files$clima_generado}")
datos_climaticos_generados <- data.table::fread(csv_filename, nThread = config$files$avbl_cores) %>%
  dplyr::mutate(date = as.Date(date)) %>% 
  tibble::as_tibble()
script$info("Lectura del csv finalizada")

# x) Reducción de trabajo (solo para pruebas)
# datos_climaticos_generados <- datos_climaticos_generados %>%
#   dplyr::filter( realization %in% c(1, 2, 3), dplyr::between(date, as.Date('1991-01-01'), as.Date('2000-12-31')) )

# f) Control de cantidad de observaciones (combinación de años y realizaciones, por ubicación)
realizaciones <- unique(datos_climaticos_generados$realization)
anos_existnts <- unique(lubridate::year(datos_climaticos_generados$date))
if (nrow(tidyr::crossing(realizaciones, anos_existnts)) < 30)
  script$warn(paste("La cantidad de observaciones derivada de la combinación de anhos y realizaciones",
                    "es menor a 30. Lo que podría no ser suficiente para algunas de las estadísticas",
                    "a ser calculadas a partir de las estadísticas móviles que serán generadas!!"))

# g) Fechas mínima y máxima
fecha.minima <- min(datos_climaticos_generados$date)
fecha.maxima <- max(datos_climaticos_generados$date)

# h) Calcular fecha minima de inicio de pentada
fecha.minima.inicio.pentada <- fecha.inicio.pentada(fecha.minima)

# i) Calcular fecha maxima de inicio y fin de pentada
fecha.maxima.inicio.pentada <- fecha.inicio.pentada(fecha.maxima)
fecha.maxima.fin.pentada    <- fecha.fin.pentada(fecha.maxima)
if (fecha.maxima.fin.pentada > fecha.maxima) {
  # Ir una pentada hacia atras
  fecha.maxima.inicio.pentada <- sumar.pentadas(fecha.maxima.inicio.pentada, -1)
  fecha.maxima.fin.pentada    <- fecha.fin.pentada(fecha.maxima.inicio.pentada)
}

rm(fecha.maxima.fin.pentada)

# j) Generar tibble con ubicaciones sobre las cuales iterar
script$info("Obtener ubicaciones sobre las cuales iterar")
ubicaciones_a_procesar <- datos_climaticos_generados %>%
  dplyr::select(dplyr::ends_with("_id"), longitude, latitude) %>%
  tibble::as_tibble() %>% dplyr::distinct()
script$info("Obtención de ubicaciones a iterar finalizada")

# ------------------------------------------------------------------------------

# -----------------------------------------------------------------------------#
# --- PASO 4. Definir funciones de agregacion ----
# -----------------------------------------------------------------------------#
ContarFaltantes <- function(x) {
  return (length(which(is.na(x))))
}
ContarDisponibles <- function(x) {
  return (length(x) - length(which(is.na(x))))
}
CalcularOcurrencia <- function(x, umbral) {
  return (length(which(x >= umbral)))
}
CalcularEstadisticasUbicacionVariable  <- function(variable, script, fechas.procesables, ubicacion,
                                                   datos.climaticos, ancho.ventana.pentadas, parametros) {
  
  # Identificar la columna con el id de la ubicación (usualmente station_id, o point_id)
  id_column <- IdentificarIdColumn(ubicacion)
  
  # Informar estado de la ejecución
  script$info(glue::glue("Procesando estadisticas para la ubicación: ",
                         "{ubicacion %>% dplyr::pull(!!id_column)}, escala: ",
                         "{ancho.ventana.pentadas/6}, variable: {variable}"))
  
  # Definir parametros para variables
  politicas.ventana        <- purrr::keep(
    .x = parametros$faltantes, 
    .p = function(politica) { 
      return (politica$ancho.ventana.pentadas == ancho.ventana.pentadas) }
  )[[1]]$politica
  parametros.faltantes     <- politicas.ventana[[variable]]
  estadisticos.calculables <- parametros$estadisticos[[variable]]
  
  # Buscar todos los datos posibles de una vez. El listado devuelto tiene que tener todas las fechas
  # posibles. Donde no hay datos, debe figurar la fecha con valor NA.
  # Como cada variable está en un columna diferente, para tomar datos de una sola variable
  # se hace un select sobre la columna asociada a la variable y no un filter!!
  registros.variable <- datos.climaticos %>%
    dplyr::select(!!rlang::sym(id_column), realization, date, value = !!variable) %>%
    dplyr::group_by(!!rlang::sym(id_column), realization) %>%
    tidyr::complete(date = base::seq.Date(min(fechas.procesables$fecha.inicio), 
                                          max(fechas.procesables$fecha.fin), by = "days")) %>%
    dplyr::ungroup()
  
  # Para cada rango de fechas:
  # 1. Validar cantidad de faltantes y cantidad de faltantes consecutivos
  # 2. Si la validacion pasa, entonces aplicar funcion de agregacion. Sino, devolver NA.
  estadisticos_x_fechas_procesables <- purrr::map_dfr(
    .x = seq(from = 1, to = nrow(fechas.procesables)),
    .f = function(fecha_seq_index) {
      fecha.inicio  <- fechas.procesables[fecha_seq_index, "fecha.inicio"]
      fecha.fin     <- fechas.procesables[fecha_seq_index, "fecha.fin"]
      
      estadisticos_x_realizacion <- purrr::map_dfr(
        .x = unique(registros.variable$realization),
        .f = function(realization) {
          
          datos.ventana <- registros.variable %>%
            dplyr::filter(realization == !!realization) %>%
            dplyr::filter(date >= fecha.inicio & date <= fecha.fin) %>%
            dplyr::mutate(faltante = ifelse(is.na(value), TRUE, FALSE))
          
          # Cantidad de faltantes (totales y secuencias de consecutivos)
          cantidad.faltantes <- length(which(is.na(datos.ventana$value)))
          cumple.validacion  <- TRUE
          if (cantidad.faltantes > parametros.faltantes$maximo) {
            cumple.validacion <- FALSE
          } else if (! is.null(parametros.faltantes$consecutivos)) {
            # Cumple la validacion de maxima cantidad de faltantes por mes.
            # Validar faltantes consecutivos.
            if (cantidad.faltantes > 0) {
              faltantes.consecutivos     <- base::rle(datos.ventana$faltante)
              max.faltantes.consecutivos <- max(faltantes.consecutivos$lengths[which(faltantes.consecutivos$values)])
            } else {
              # Al no haber faltantes, no puede haber faltantes consecutivos.
              max.faltantes.consecutivos <- 0
            }
            
            if (max.faltantes.consecutivos > parametros.faltantes$consecutivos) {
              cumple.validacion <- FALSE
            }
          }
          
          # Calcular estadisticos
          estadisticos <- purrr::map_dfr(
            .x = seq(from = 1, to = length(estadisticos.calculables)),
            .f = function(estadistico_seq_index) {
              estadistico <- estadisticos.calculables[[estadistico_seq_index]]
              if (! estadistico$validable || cumple.validacion) {
                param <- append(list(x = datos.ventana$value), estadistico$parametros)
                valor <- do.call(what = estadistico$funcion, args = param)
              } else {
                valor <- NA
              }
              
              return (tibble::tibble(estadistico = estadistico$id, 
                                     valor = valor))
            }
          )
          
          return (tibble::tibble(realizacion = realization, 
                                 metodo_imputacion_id = 0) %>% 
                    tidyr::crossing(estadisticos))
        }
      )
      
      return (tibble::tibble(fecha_desde = fecha.inicio, 
                             fecha_hasta = fecha.fin) %>% 
                tidyr::crossing(estadisticos_x_realizacion))
    }
  )
  
  return (ubicacion %>% dplyr::select(dplyr::ends_with("_id")) %>%
            dplyr::mutate(variable_id = variable, ancho_ventana_pentadas = ancho.ventana.pentadas) %>%
            tidyr::crossing(estadisticos_x_fechas_procesables))
}
CalcularEstadisticasUbicacion <- function(input.value, script, config, variables,
                                          fecha.minima.inicio.pentada, fecha.maxima.inicio.pentada, 
                                          datos_climaticos_completos) {
  # Obtener la ubicación para la cual se calcularán los índices
  ubicacion <- input.value
  
  # Identificar la columna con el id de la ubicación (usualmente station_id, o point_id)
  id_column <- IdentificarIdColumn(ubicacion)
  
  # Informar estado de la ejecución
  script$info(glue::glue("Procesando estadisticas para la ubicación con ",
                         "{id_column} = {ubicacion %>% dplyr::pull(!!id_column)} ",
                         "(lon: {ubicacion$longitude}, lat: {ubicacion$latitude})"))
  
  # Filtrar datos_climaticos_completos
  datos.climaticos = datos_climaticos_completos %>% 
    dplyr::filter(!!rlang::sym(id_column) == dplyr::pull(ubicacion, !!id_column))

  # Sabiendo la fecha minima de inicio de la pentada y la fecha maxima, calcular fechas procesables para cada ancho de ventana.
  # Calcular estadisticos por variable y ancho de ventana.
  estadisticas.ubicacion  <- purrr::map_dfr(
    .x = config$params$ancho.ventana.pentadas,
    .f = function(ancho.ventana.pentadas) {
      # Informar estado de la ejecución
      script$info(glue::glue("Procesando estadisticas para la ubicación: ",
                             "{ubicacion %>% dplyr::pull(!!id_column)}, pentada: {ancho.ventana.pentadas}"))
      # Genero un data frame de fechas procesables con 2 columnas: fecha inicio, fecha fin
      fechas.procesables.inicio <- seq.pentadas(fecha.minima.inicio.pentada, fecha.maxima.inicio.pentada)
      fechas.procesables        <- purrr::map_dfr(
        .x = fechas.procesables.inicio,
        .f = function(fecha) {
          fecha.inicio.ventana <- fecha
          fecha.fin.ventana    <- fecha.fin.pentada(sumar.pentadas(fecha.inicio.ventana, ancho.ventana.pentadas - 1))
          return (data.frame(fecha.inicio = fecha.inicio.ventana, fecha.fin = fecha.fin.ventana))
        }
      ) %>% dplyr::filter(fecha.fin <= fecha.fin.pentada(fecha.maxima.inicio.pentada))

      if (nrow(fechas.procesables) > 0) {
        # Para cada variable, calcular las estadisticas correspondientes. Consolidar todos los resultados en un data frame.
        # i. Calculo de estadisticas para la estacion.
        estadisticas <- purrr::map_dfr(
          .x = variables,
          .f = CalcularEstadisticasUbicacionVariable,
          script = script,
          fechas.procesables = fechas.procesables, 
          ubicacion = ubicacion,
          datos.climaticos = datos.climaticos,
          ancho.ventana.pentadas = ancho.ventana.pentadas,
          parametros = config$params
        )
        return (estadisticas)
      } else {
        return (NULL)
      }
    }
  )

  if (nrow(estadisticas.ubicacion) > 0) {
    # ii. Informar retorno de datos
    script$info(paste("Retornando estadisticas", 
                      "desde", min(estadisticas.ubicacion$fecha_desde), 
                      "hasta", max(estadisticas.ubicacion$fecha_hasta),
                      "para la ubicación", dplyr::pull(ubicacion, !!id_column)))
  } else {
    # No hay datos nuevos para agregar
    script$info(paste("No hay nuevas fechas procesables para la ubicación", dplyr::pull(ubicacion, !!id_column)))
  }
  return (estadisticas.ubicacion)
}
# ------------------------------------------------------------------------------

# -----------------------------------------------------------------------------#
# --- PASO 6. Ejecutar cálculo de estadísticas móviles de manera distriuída ----
# -----------------------------------------------------------------------------#

# Definir nombre de la función a ser distribuida y nombre de archivos .log y .out de corridas anteriores
function_name <- "CalcularEstadisticasUbicacion"
task_logfile <- glue::glue("{config$dir$run}/{script_name}-{function_name}.log")
task_outfile <- glue::glue("{config$dir$run}/{script_name}-{function_name}.out")

# Borrar archivos .log y .out de corridas anteriores
if (file.exists(task_logfile))
  file.remove(task_logfile)
if (file.exists(task_outfile))
  file.remove(task_outfile)

# Crear tarea distribuida y ejecutarla
task.estadisticas <- Task$new(parent.script = script,
                              func.name = function_name,
                              packages = list.of.packages)

# Informar inicio de ejecución 
script$info(paste0("Calculando estadisticas moviles para un ancho de venta de (", 
                   paste0(config$params$ancho.ventana.pentadas, collapse = ", "), ") pentadas"))
# Ejecutar tarea distribuida
resultados.estadisticas <- task.estadisticas$run(number.of.processes = config$max.procesos,
                                                 input.values = ubicaciones_a_procesar, 
                                                 config = config, variables = c("tmax", "tmin", "prcp"),
                                                 fecha.minima.inicio.pentada = fecha.minima.inicio.pentada,
                                                 fecha.maxima.inicio.pentada = fecha.maxima.inicio.pentada,
                                                 datos_climaticos_completos = datos_climaticos_generados)

# Agregar log de la tarea al log del script
file.append(script_logfile, task_logfile)

# Si hay errores, terminar ejecucion
task.estadisticas.errors <- task.estadisticas$getErrors()
if (length(task.estadisticas.errors) > 0) {
  for (error.obj in task.estadisticas.errors) {
    id_column <- IdentificarIdColumn(ubicaciones_a_procesar %>% dplyr::top_n(1))
    script$warn(glue::glue("({id_column}={error.obj$input.value[[id_column]]}): {error.obj$error}"))
  }
  script$error("Finalizando script de forma ANORMAL")
}

# Transformar resultados a un objeto de tipo tibble
resultados.estadisticas.tibble <- resultados.estadisticas %>% purrr::map_dfr(~.x)

# Guardar resultados en un archivo fácil de compartir
results_filename <- glue::glue("{config$dir$data}/{config$files$estadisticas_moviles$resultados}")
script$info(glue::glue("Guardando resultados en el archivo {results_filename}"))
data.table::fwrite(resultados.estadisticas.tibble, file = results_filename, nThread = config$files$avbl_cores)

# ------------------------------------------------------------------------------

# -----------------------------------------------------------------------------#
# --- PASO 7. Finalizar script ----
# -----------------------------------------------------------------------------#

# a) Finalizar script
script$stop()

# b) Crear archivo .info
info_filename <- glue::glue("{config$dir$data}/{config$files$estadisticas_moviles$info_corrida}")
if (file.exists(info_filename))
  file.remove(info_filename)
file.copy(from = script_logfile, to = info_filename)

# ------------------------------------------------------------------------------
